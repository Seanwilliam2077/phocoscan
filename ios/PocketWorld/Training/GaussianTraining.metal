// On-device 3D Gaussian Splatting training (forward + backward), after the original 3DGS
// rasterizer (Kerbl et al. 2023) and gsplat. Parameters per Gaussian: mean, log-scale, rotation
// quaternion (w, x, y, z), degree-0 colour (f_dc) and opacity logit. Cameras use the OpenCV
// convention (x right, y down, z forward); pixel centres sit at integer coordinates.
#include <metal_stdlib>
using namespace metal;

constant float SH_C0 = 0.28209479177387814f;
constant uint TILE = 16;
constant uint RADIX_THREADS = 256;
constant uint RADIX_ROUNDS = 16;
constant uint RADIX_BLOCK = 4096; // RADIX_THREADS * RADIX_ROUNDS
constant uint GRAD2D_STRIDE = 12; // xy(2) conic(3) colour(3) opacity(1), padded

struct CameraParams {
    float4 r0, r1, r2;   // rows of the world → camera rotation (OpenCV)
    float4 t;            // world → camera translation
    float4 intr;         // fx, fy, cx, cy (training resolution)
    uint4 dims;          // width, height, tilesX, tilesY
    float4 lim;          // tan limit x, tan limit y, near plane, max radius (px)
    float4 opts;         // min alpha (1/255), radius in sigmas (3), unused, unused
};

struct AdamParams {
    float4 lrMean, lrScale, lrQuat, lrColorOp; // per component
    float beta1, beta2, epsilon, bc1;          // bc1 = 1 - beta1^t
    float bc2, noiseScale, step, _pad;         // bc2 = 1 - beta2^t
};

struct RegParams {
    float opacity;   // weight of mean(opacity)
    float scale;     // weight of mean(scale)
    float count;     // number of Gaussians (normalisation)
    float _pad;
};

inline float sigmoid(float x) { return 1.0f / (1.0f + exp(-x)); }

/// Rotation matrix (columns) of a unit quaternion (w, x, y, z).
inline float3x3 quatToMatrix(float4 q) {
    float w = q.x, x = q.y, y = q.z, z = q.w;
    return float3x3(float3(1 - 2 * (y * y + z * z), 2 * (x * y + w * z), 2 * (x * z - w * y)),
                    float3(2 * (x * y - w * z), 1 - 2 * (x * x + z * z), 2 * (y * z + w * x)),
                    float3(2 * (x * z + w * y), 2 * (y * z - w * x), 1 - 2 * (x * x + y * y)));
}

inline int4 tileRect(float2 xy, float radius, uint tilesX, uint tilesY) {
    int x0 = max(0, int(floor((xy.x - radius) / float(TILE))));
    int x1 = min(int(tilesX), int(floor((xy.x + radius) / float(TILE))) + 1);
    int y0 = max(0, int(floor((xy.y - radius) / float(TILE))));
    int y1 = min(int(tilesY), int(floor((xy.y + radius) / float(TILE))) + 1);
    return int4(x0, y0, x1, y1);
}

// MARK: - Projection

struct Projected {
    float3 p;       // camera-space position
    float3 t0, t1;  // rows of J·W
    float3x3 R, M, sigma;
    float3 s;
    float4 q;       // normalised quaternion
    float qNorm;
    float A, B, C, det;
    float2 xy;
    bool clampX, clampY;
    float clampedX, clampedY; // x/z and y/z after clamping
    bool valid;
};

inline Projected project(float3 mean, float3 logScale, float4 quat, constant CameraParams& cam) {
    Projected o;
    o.valid = false;
    o.p = float3(dot(cam.r0.xyz, mean), dot(cam.r1.xyz, mean), dot(cam.r2.xyz, mean)) + cam.t.xyz;
    if (o.p.z < cam.lim.z) return o;
    o.qNorm = length(quat);
    if (o.qNorm < 1e-8f) return o;
    o.q = quat / o.qNorm;
    o.s = exp(logScale);
    o.R = quatToMatrix(o.q);
    o.M = float3x3(o.R[0] * o.s.x, o.R[1] * o.s.y, o.R[2] * o.s.z);
    o.sigma = o.M * transpose(o.M);
    float fx = cam.intr.x, fy = cam.intr.y, invz = 1.0f / o.p.z;
    float rx = o.p.x * invz, ry = o.p.y * invz;
    o.clampedX = clamp(rx, -cam.lim.x, cam.lim.x);
    o.clampedY = clamp(ry, -cam.lim.y, cam.lim.y);
    o.clampX = o.clampedX != rx;
    o.clampY = o.clampedY != ry;
    float j00 = fx * invz, j02 = -fx * o.clampedX * invz;
    float j11 = fy * invz, j12 = -fy * o.clampedY * invz;
    o.t0 = j00 * cam.r0.xyz + j02 * cam.r2.xyz;
    o.t1 = j11 * cam.r1.xyz + j12 * cam.r2.xyz;
    float3 st0 = o.sigma * o.t0, st1 = o.sigma * o.t1;
    o.A = dot(o.t0, st0) + 0.3f;
    o.B = dot(o.t0, st1);
    o.C = dot(o.t1, st1) + 0.3f;
    o.det = o.A * o.C - o.B * o.B;
    if (!(o.det > 1e-12f)) return o;
    o.xy = float2(fx * o.p.x * invz + cam.intr.z, fy * o.p.y * invz + cam.intr.w);
    o.valid = true;
    return o;
}

kernel void preprocessForward(device const float4* means [[buffer(0)]],
                              device const float4* logScales [[buffer(1)]],
                              device const float4* quats [[buffer(2)]],
                              device const float4* colorOp [[buffer(3)]],
                              constant CameraParams& cam [[buffer(4)]],
                              device float4* projXY [[buffer(5)]],     // x, y, depth, radius
                              device float4* conicOp [[buffer(6)]],    // a, b, c, opacity
                              device float4* rgb [[buffer(7)]],
                              device uint* tilesTouched [[buffer(8)]],
                              constant uint& count [[buffer(9)]],
                              uint i [[thread_position_in_grid]]) {
    if (i >= count) return;
    tilesTouched[i] = 0;
    projXY[i] = float4(0);
    Projected g = project(means[i].xyz, logScales[i].xyz, quats[i], cam);
    if (!g.valid) return;
    float mid = 0.5f * (g.A + g.C);
    float lambda = mid + sqrt(max(0.1f, mid * mid - g.det));
    float radius = min(ceil(cam.opts.y * sqrt(lambda)), cam.lim.w);
    int4 rect = tileRect(g.xy, radius, cam.dims.z, cam.dims.w);
    if (rect.z <= rect.x || rect.w <= rect.y) return;
    float invdet = 1.0f / g.det;
    float4 co = colorOp[i];
    projXY[i] = float4(g.xy, g.p.z, radius);
    conicOp[i] = float4(g.C * invdet, -g.B * invdet, g.A * invdet, sigmoid(co.w));
    rgb[i] = float4(max(float3(0), 0.5f + SH_C0 * co.xyz), 0);
    tilesTouched[i] = uint((rect.z - rect.x) * (rect.w - rect.y));
}

kernel void emitKeys(device const float4* projXY [[buffer(0)]],
                     device const uint* offsets [[buffer(1)]],
                     constant CameraParams& cam [[buffer(2)]],
                     device uint* keyDepth [[buffer(3)]],
                     device uint* keyTile [[buffer(4)]],
                     device uint* values [[buffer(5)]],
                     constant uint& count [[buffer(6)]],
                     uint i [[thread_position_in_grid]]) {
    if (i >= count) return;
    float4 pr = projXY[i];
    if (pr.w <= 0) return;
    int4 rect = tileRect(pr.xy, pr.w, cam.dims.z, cam.dims.w);
    uint o = offsets[i];
    uint depthBits = as_type<uint>(pr.z); // positive floats sort like their bit patterns
    for (int y = rect.y; y < rect.w; y++) {
        for (int x = rect.x; x < rect.z; x++) {
            keyTile[o] = uint(y) * cam.dims.z + uint(x);
            keyDepth[o] = depthBits;
            values[o] = i;
            o++;
        }
    }
}

// MARK: - Scan (exclusive prefix sum, 1024 elements per threadgroup)

kernel void scanBlocks(device const uint* input [[buffer(0)]],
                       device uint* output [[buffer(1)]],
                       device uint* blockSums [[buffer(2)]],
                       constant uint& n [[buffer(3)]],
                       uint gid [[thread_position_in_grid]],
                       uint lid [[thread_position_in_threadgroup]],
                       uint group [[threadgroup_position_in_grid]],
                       uint threads [[threads_per_threadgroup]],
                       uint lane [[thread_index_in_simdgroup]],
                       uint sg [[simdgroup_index_in_threadgroup]],
                       uint simdWidth [[threads_per_simdgroup]]) {
    threadgroup uint sums[64];
    uint v = gid < n ? input[gid] : 0;
    uint inclusive = simd_prefix_inclusive_sum(v);
    if (lane == simdWidth - 1) sums[sg] = inclusive;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    uint groups = threads / simdWidth;
    if (sg == 0) {
        uint s = lane < groups ? sums[lane] : 0;
        uint before = simd_prefix_exclusive_sum(s);
        if (lane < groups) sums[lane] = before;
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    uint exclusive = sums[sg] + inclusive - v;
    if (gid < n) output[gid] = exclusive;
    if (lid == threads - 1) blockSums[group] = exclusive + v;
}

kernel void addBlockOffsets(device uint* data [[buffer(0)]],
                            device const uint* offsets [[buffer(1)]],
                            constant uint& n [[buffer(2)]],
                            uint gid [[thread_position_in_grid]],
                            uint group [[threadgroup_position_in_grid]]) {
    if (gid < n) data[gid] += offsets[group];
}

// MARK: - Radix sort (stable, 8 bits per pass, 4096 keys per threadgroup)

kernel void radixHistogram(device const uint* keys [[buffer(0)]],
                           device uint* histogram [[buffer(1)]],  // digit-major: digit * blocks + block
                           constant uint& n [[buffer(2)]],
                           constant uint& shift [[buffer(3)]],
                           constant uint& blocks [[buffer(4)]],
                           uint lid [[thread_position_in_threadgroup]],
                           uint group [[threadgroup_position_in_grid]]) {
    threadgroup atomic_uint counts[256];
    atomic_store_explicit(&counts[lid], 0, memory_order_relaxed);
    threadgroup_barrier(mem_flags::mem_threadgroup);
    uint base = group * RADIX_BLOCK;
    for (uint k = 0; k < RADIX_ROUNDS; k++) {
        uint idx = base + k * RADIX_THREADS + lid;
        if (idx < n) atomic_fetch_add_explicit(&counts[(keys[idx] >> shift) & 255u], 1, memory_order_relaxed);
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    histogram[lid * blocks + group] = atomic_load_explicit(&counts[lid], memory_order_relaxed);
}

kernel void radixScatter(device const uint* digitKeys [[buffer(0)]],
                         device const uint* depthIn [[buffer(1)]],
                         device const uint* tileIn [[buffer(2)]],
                         device const uint* valueIn [[buffer(3)]],
                         device uint* depthOut [[buffer(4)]],
                         device uint* tileOut [[buffer(5)]],
                         device uint* valueOut [[buffer(6)]],
                         device const uint* offsets [[buffer(7)]], // scanned histogram
                         constant uint& n [[buffer(8)]],
                         constant uint& shift [[buffer(9)]],
                         constant uint& blocks [[buffer(10)]],
                         uint lid [[thread_position_in_threadgroup]],
                         uint group [[threadgroup_position_in_grid]],
                         uint lane [[thread_index_in_simdgroup]],
                         uint sg [[simdgroup_index_in_threadgroup]]) {
    threadgroup uint simdCounts[8][256];
    threadgroup uint digitBase[256];
    digitBase[lid] = offsets[lid * blocks + group];
    threadgroup_barrier(mem_flags::mem_threadgroup);
    uint base = group * RADIX_BLOCK;
    ulong below = (1ul << lane) - 1ul;
    for (uint round = 0; round < RADIX_ROUNDS; round++) {
        uint idx = base + round * RADIX_THREADS + lid;
        bool valid = idx < n;
        uint digit = valid ? (digitKeys[idx] >> shift) & 255u : 0u;
        // Lanes holding the same digit, in lane order (stable within the SIMD group).
        ulong same = (ulong)(simd_vote::vote_t)simd_ballot(valid);
        for (uint b = 0; b < 8; b++) {
            bool bit = ((digit >> b) & 1u) != 0;
            ulong ones = (ulong)(simd_vote::vote_t)simd_ballot(valid && bit);
            same &= bit ? ones : ~ones;
        }
        uint rank = popcount(same & below);
        uint total = popcount(same);
        for (uint s = 0; s < 8; s++) simdCounts[s][lid] = 0;
        threadgroup_barrier(mem_flags::mem_threadgroup);
        if (valid && rank == 0) simdCounts[sg][digit] = total;
        threadgroup_barrier(mem_flags::mem_threadgroup);
        uint run = 0;
        for (uint s = 0; s < 8; s++) {
            uint c = simdCounts[s][lid];
            simdCounts[s][lid] = run;
            run += c;
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
        if (valid) {
            uint destination = digitBase[digit] + simdCounts[sg][digit] + rank;
            depthOut[destination] = depthIn[idx];
            tileOut[destination] = tileIn[idx];
            valueOut[destination] = valueIn[idx];
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
        digitBase[lid] += run;
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
}

/// Start/end of each tile's run. Separate 32-bit stores: the start and end of one tile are often
/// written by different threads, and a vector store would race.
kernel void tileRanges(device const uint* tiles [[buffer(0)]],
                       device uint* ranges [[buffer(1)]],   // 2 per tile: start, end
                       constant uint& n [[buffer(2)]],
                       uint i [[thread_position_in_grid]]) {
    if (i >= n) return;
    uint t = tiles[i];
    if (i == 0 || tiles[i - 1] != t) ranges[2 * t] = i;
    if (i == n - 1 || tiles[i + 1] != t) ranges[2 * t + 1] = i + 1;
}

// MARK: - Rasterisation

kernel void rasterizeForward(device const uint2* ranges [[buffer(0)]],
                             device const uint* values [[buffer(1)]],
                             device const float4* projXY [[buffer(2)]],
                             device const float4* conicOp [[buffer(3)]],
                             device const float4* rgb [[buffer(4)]],
                             constant CameraParams& cam [[buffer(5)]],
                             device float4* outColor [[buffer(6)]],   // rgb, final transmittance
                             device uint* outCount [[buffer(7)]],     // contributors up to the last one used
                             uint2 tile [[threadgroup_position_in_grid]],
                             uint2 local [[thread_position_in_threadgroup]],
                             uint lidx [[thread_index_in_threadgroup]]) {
    threadgroup float2 sXY[256];
    threadgroup float4 sCO[256];
    threadgroup float4 sRGB[256];
    uint width = cam.dims.x, height = cam.dims.y;
    uint px = tile.x * TILE + local.x, py = tile.y * TILE + local.y;
    bool inside = px < width && py < height;
    float2 pixel = float2(px, py);
    uint2 range = ranges[tile.y * cam.dims.z + tile.x];
    float T = 1.0f;
    float3 color = float3(0);
    uint last = 0;
    bool done = !inside;
    for (uint start = range.x; start < range.y; start += 256) {
        uint j = start + lidx;
        if (j < range.y) {
            uint g = values[j];
            sXY[lidx] = projXY[g].xy;
            sCO[lidx] = conicOp[g];
            sRGB[lidx] = rgb[g];
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
        uint batch = min(256u, range.y - start);
        for (uint k = 0; k < batch && !done; k++) {
            float2 d = sXY[k] - pixel;
            float4 co = sCO[k];
            float power = -0.5f * (co.x * d.x * d.x + co.z * d.y * d.y) - co.y * d.x * d.y;
            if (power > 0) continue;
            float alpha = min(0.99f, co.w * exp(power));
            if (alpha < cam.opts.x) continue;
            float next = T * (1 - alpha);
            if (next < 1e-4f) { done = true; break; }
            color += sRGB[k].xyz * alpha * T;
            T = next;
            last = start - range.x + k + 1;
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    if (inside) {
        outColor[py * width + px] = float4(color, T);
        outCount[py * width + px] = last;
    }
}

// Measure actual visible alpha mass against the subject mask, respecting front-to-back
// occlusion. Reverse traversal reconstructs exactly the same transmittance as the renderer.
// Separate scratch only: never writes parameters, Adam, gradients or density state.
kernel void rasterizeSubjectEvidence(device const uint2* ranges [[buffer(0)]],device const uint* values [[buffer(1)]],
    device const float4* projXY [[buffer(2)]],device const float4* conicOp [[buffer(3)]],constant CameraParams& cam [[buffer(4)]],
    device const float4* outColor [[buffer(5)]],device const uint* outCount [[buffer(6)]],device const uchar4* target [[buffer(7)]],
    device atomic_float* evidence [[buffer(8)]],device const float4* means [[buffer(9)]],
    device const float4* scales [[buffer(10)]],device const float4* quats [[buffer(11)]],device const float4* rgb [[buffer(12)]],
    uint2 tile [[threadgroup_position_in_grid]],uint2 local [[thread_position_in_threadgroup]],
    uint lidx [[thread_index_in_threadgroup]],uint lane [[thread_index_in_simdgroup]]) {
    threadgroup float2 sXY[256];threadgroup float4 sCO[256];threadgroup uint sID[256];
    threadgroup float4 sAxis[3][256];
    threadgroup float4 sRGB[256];
    uint width=cam.dims.x,height=cam.dims.y,px=tile.x*TILE+local.x,py=tile.y*TILE+local.y;
    bool inside=px<width && py<height;
    uint pixel=inside ? py*width+px:0;
    float T=inside ? outColor[pixel].w:1;
    uint last=inside ? outCount[pixel]:0;
    float3 behind=0, rendered=inside ? outColor[pixel].xyz:float3(0);
    float3 reference=inside ? float3(target[pixel].xyz)/255.0f:float3(0);
    float mask=0;
    if(inside) for(int y=-1;y<=1;y++) for(int x=-1;x<=1;x++) {
        int2 xy=clamp(int2(px,py)+int2(x,y),int2(0),int2(width-1,height-1));
        mask=max(mask,float(target[xy.y*width+xy.x].w)/255.0f);
    }
    uint2 range=ranges[tile.y*cam.dims.z+tile.x];
    for(int end=int(range.y-range.x);end>0;end-=256) {
        int begin=max(0,end-256),position=end-1-int(lidx);
        if(position>=begin) {
            uint g=values[range.x+uint(position)];sID[lidx]=g;sXY[lidx]=projXY[g].xy;sCO[lidx]=conicOp[g];
            sRGB[lidx]=rgb[g];
            Projected p=project(means[g].xyz,scales[g].xyz,quats[g],cam);
            for(uint axis=0;axis<3;axis++) {
                float2 a=float2(dot(p.t0,p.M[axis]),dot(p.t1,p.M[axis]));
                float2 q=float2(p.C*a.x-p.B*a.y,p.A*a.y-p.B*a.x)/p.det;
                // E[z_axis² | screen pixel] under the same projected Gaussian,
                // including low-pass variance. An unobserved axis stays at one.
                sAxis[axis][lidx]=float4(q,max(0.0f,1-dot(a,q)),0);
            }
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
        for(int k=0;k<end-begin;k++) {
            float2 d=sXY[k]-float2(px,py);float4 co=sCO[k];
            float power=-0.5f*(co.x*d.x*d.x+co.z*d.y*d.y)-co.y*d.x*d.y;
            float alpha=min(0.99f,co.w*exp(power));
            bool active=inside && uint(end-1-k)<last && power<=0 && alpha>=cam.opts.x;
            float mass=0;
            if(active) { T/=1-alpha;mass=alpha*T; }
            // Image change if this Gaussian alone were removed within the rendered
            // contribution list. Early termination/sort cutoffs are held fixed:
            // this is evidence, not a replacement for comparing the exported model.
            float3 delta=mass*(sRGB[k].xyz-behind);
            float cost=dot(abs(rendered-delta-reference)-abs(rendered-reference),float3(1.0f/3.0f))*mask;
            if(active) behind=alpha*sRGB[k].xyz+(1-alpha)*behind;
            float fg=simd_sum(mass*mask),bg=simd_sum(mass*(1-mask));
            float removal=simd_sum(cost);
            if(simd_any(active) && lane==0) {
                atomic_fetch_add_explicit(evidence+12*sID[k],fg,memory_order_relaxed);
                atomic_fetch_add_explicit(evidence+12*sID[k]+1,bg,memory_order_relaxed);
                atomic_fetch_add_explicit(evidence+12*sID[k]+8,removal,memory_order_relaxed);
            }
            for(uint axis=0;axis<3;axis++) {
                float4 a=sAxis[axis][k];float z=dot(a.xy,d),moment=a.z+z*z;
                float fm=simd_sum(mass*mask*moment),bm=simd_sum(mass*(1-mask)*moment);
                if(simd_any(active) && lane==0) {
                    atomic_fetch_add_explicit(evidence+12*sID[k]+2+axis,fm,memory_order_relaxed);
                    atomic_fetch_add_explicit(evidence+12*sID[k]+5+axis,bm,memory_order_relaxed);
                }
            }
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
}

/// RGBA8 targets keep sRGB bytes; alpha may carry a subject mask without altering RGB.
// One active target on the GPU. Integer area reduction matches half-pixel camera scaling,
// including odd image dimensions; sensor orientation is unchanged.
kernel void trainingTarget(device const uchar4* source [[buffer(0)]],
                           device uchar4* target [[buffer(1)]],
                           constant uint4& sizes [[buffer(2)]],
                           uint i [[thread_position_in_grid]]) {
    if (i >= sizes.z * sizes.w) return;
    uint x = i % sizes.z, y = i / sizes.z;
    float2 lo = float2(x, y) * float2(sizes.xy) / float2(sizes.zw);
    float2 hi = float2(x + 1, y + 1) * float2(sizes.xy) / float2(sizes.zw);
    float4 sum = 0; float area = 0;
    for (uint sy = uint(lo.y); sy < min(sizes.y, uint(ceil(hi.y))); ++sy) {
        for (uint sx = uint(lo.x); sx < min(sizes.x, uint(ceil(hi.x))); ++sx) {
            float w = (min(hi.x, float(sx + 1)) - max(lo.x, float(sx))) *
                      (min(hi.y, float(sy + 1)) - max(lo.y, float(sy)));
            sum += float4(source[sy * sizes.x + sx]) * w; area += w;
        }
    }
    target[i] = uchar4(round(sum / max(area, 1e-8f)));
}

// 5x5 Gaussian-window SSIM (sigma 1): a mobile-sized window. Renormalise at image edges.
// Three coefficient fields let the backward gather avoid global floating-point atomics.
inline float structuralWeight(int x, int y) { return exp(-0.5f * float(x*x + y*y)); }
inline float structuralNorm(int2 p, uint2 size) {
    float sum = 0;
    for (int y = -2; y <= 2; ++y) for (int x = -2; x <= 2; ++x) {
        int2 q = p + int2(x, y);
        if (all(q >= 0) && all(q < int2(size))) sum += structuralWeight(x, y);
    }
    return sum;
}
kernel void structuralStatistics(device const float4* rendered [[buffer(0)]],
                                 device const uchar4* target [[buffer(1)]],
                                 device float4* dMean [[buffer(2)]],
                                 device float4* dSquare [[buffer(3)]],
                                 device float4* dCross [[buffer(4)]],
                                 device float* objective [[buffer(5)]],
                                 constant uint2& size [[buffer(6)]],
                                 constant float4& loss [[buffer(7)]],
                                 uint i [[thread_position_in_grid]]) {
    if (i >= size.x * size.y) return;
    int2 p = int2(i % size.x, i / size.x);
    float norm = structuralNorm(p, size);
    float weight = mix(loss.z, loss.y, float(target[i].w) / 255.0f);
    float lambda = loss.x;
    float3 mx=0, my=0, ex2=0, ey2=0, exy=0;
    for (int y=-2; y<=2; ++y) for (int x=-2; x<=2; ++x) {
        int2 q=p+int2(x,y); if (any(q<0) || any(q>=int2(size))) continue;
        uint j=uint(q.y)*size.x+uint(q.x);
        float w=structuralWeight(x,y)/norm;
        float3 a=rendered[j].xyz, b=float3(target[j].xyz)/255.0f;
        mx+=w*a; my+=w*b; ex2+=w*a*a; ey2+=w*b*b; exy+=w*a*b;
    }
    float3 A=2*mx*my+0.0001f, B=2*(exy-mx*my)+0.0009f;
    float3 C=mx*mx+my*my+0.0001f;
    // The weighted variance is nonnegative analytically; constants keep division stable.
    float3 D=ex2-mx*mx+ey2-my*my+0.0009f;
    float3 inv=1/(C*D), score=A*B*inv;
    dMean[i]=float4((2*my*(B-A)*inv-score*(2*mx/C-2*mx/D))*weight/norm,0);
    dSquare[i]=float4(-score/D*weight/norm,0);
    dCross[i]=float4(2*A*inv*weight/norm,0);
    float3 diff=abs(rendered[i].xyz-float3(target[i].xyz)/255.0f);
    objective[i]=weight*dot((1-lambda)*diff+lambda*(1-score),float3(1.0f/3));
}
kernel void structuralGradient(device const float4* rendered [[buffer(0)]],
                               device const uchar4* target [[buffer(1)]],
                               device const float4* dMean [[buffer(2)]],
                               device const float4* dSquare [[buffer(3)]],
                               device const float4* dCross [[buffer(4)]],
                               device float4* gradient [[buffer(5)]],
                               device float* absError [[buffer(6)]],
                               constant uint2& size [[buffer(7)]],
                               constant float4& loss [[buffer(8)]],
                               uint i [[thread_position_in_grid]]) {
    if (i>=size.x*size.y) return;
    int2 p=int2(i%size.x,i/size.x);
    float3 a=rendered[i].xyz,b=float3(target[i].xyz)/255.0f,g=0;
    for (int y=-2;y<=2;++y) for (int x=-2;x<=2;++x) {
        int2 q=p+int2(x,y); if (any(q<0)||any(q>=int2(size))) continue;
        uint j=uint(q.y)*size.x+uint(q.x);
        g+=structuralWeight(x,y)*(dMean[j].xyz+2*a*dSquare[j].xyz+b*dCross[j].xyz);
    }
    float weight = mix(loss.z, loss.y, float(target[i].w) / 255.0f);
    gradient[i]=float4(((1-loss.x)*weight*sign(a-b)-loss.x*g)/float(size.x*size.y*3),0);
    absError[i]=dot(abs(a-b),float3(1.0f/3));
}

kernel void l1LossGradient(device const float4* rendered [[buffer(0)]],
                           device const uchar4* target [[buffer(1)]],
                           device float4* dLdColor [[buffer(2)]],
                           device float* absError [[buffer(3)]],
                           constant uint& pixels [[buffer(4)]],
                           constant float4& loss [[buffer(5)]],
                           uint i [[thread_position_in_grid]]) {
    if (i >= pixels) return;
    float3 diff = rendered[i].xyz - float3(target[i].xyz) / 255.0f;
    float weight = mix(loss.z, loss.y, float(target[i].w) / 255.0f);
    dLdColor[i] = float4(weight * sign(diff) / float(pixels * 3), 0);
    absError[i] = weight * (abs(diff.x) + abs(diff.y) + abs(diff.z)) / 3.0f;
}

kernel void rasterizeBackward(device const uint2* ranges [[buffer(0)]],
                              device const uint* values [[buffer(1)]],
                              device const float4* projXY [[buffer(2)]],
                              device const float4* conicOp [[buffer(3)]],
                              device const float4* rgb [[buffer(4)]],
                              constant CameraParams& cam [[buffer(5)]],
                              device const float4* outColor [[buffer(6)]],
                              device const uint* outCount [[buffer(7)]],
                              device const float4* dLdColor [[buffer(8)]],
                              device atomic_float* grad2D [[buffer(9)]],
                              uint2 tile [[threadgroup_position_in_grid]],
                              uint2 local [[thread_position_in_threadgroup]],
                              uint lidx [[thread_index_in_threadgroup]],
                              uint lane [[thread_index_in_simdgroup]]) {
    threadgroup float2 sXY[256];
    threadgroup float4 sCO[256];
    threadgroup float4 sRGB[256];
    threadgroup uint sID[256];
    uint width = cam.dims.x, height = cam.dims.y;
    uint px = tile.x * TILE + local.x, py = tile.y * TILE + local.y;
    bool inside = px < width && py < height;
    uint pixelIndex = inside ? py * width + px : 0;
    float2 pixel = float2(px, py);
    uint2 range = ranges[tile.y * cam.dims.z + tile.x];
    float T = inside ? outColor[pixelIndex].w : 1.0f;
    uint last = inside ? outCount[pixelIndex] : 0;
    float3 dPixel = inside ? dLdColor[pixelIndex].xyz : float3(0);
    float3 accum = float3(0), lastColor = float3(0);
    float lastAlpha = 0;
    int total = int(range.y - range.x);
    for (int end = total; end > 0; end -= 256) {
        int begin = max(0, end - 256);
        int position = end - 1 - int(lidx);   // batch loaded back to front
        if (position >= begin) {
            uint g = values[range.x + uint(position)];
            sID[lidx] = g;
            sXY[lidx] = projXY[g].xy;
            sCO[lidx] = conicOp[g];
            sRGB[lidx] = rgb[g];
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
        int batch = end - begin;
        for (int k = 0; k < batch; k++) {
            uint position = uint(end - 1 - k);
            float2 d = sXY[k] - pixel;
            float4 co = sCO[k];
            float power = -0.5f * (co.x * d.x * d.x + co.z * d.y * d.y) - co.y * d.x * d.y;
            float G = exp(power);
            float alpha = min(0.99f, co.w * G);
            bool active = inside && position < last && power <= 0 && alpha >= cam.opts.x;
            float3 gColor = float3(0), gConic = float3(0);
            float2 gXY = float2(0);
            float gOpacity = 0;
            if (active) {
                T = T / (1 - alpha);
                float3 c = sRGB[k].xyz;
                gColor = alpha * T * dPixel;
                accum = lastAlpha * lastColor + (1 - lastAlpha) * accum;
                lastColor = c;
                float dAlpha = dot(c - accum, dPixel) * T;
                lastAlpha = alpha;
                float dG = co.w * dAlpha;
                float gdx = G * d.x, gdy = G * d.y;
                gXY = dG * float2(-gdx * co.x - gdy * co.y, -gdy * co.z - gdx * co.y);
                gConic = dG * float3(-0.5f * gdx * d.x, -gdx * d.y, -0.5f * gdy * d.y);
                gOpacity = G * dAlpha;
            }
            gColor = simd_sum(gColor);
            gConic = simd_sum(gConic);
            float2 gAbs = float2(0);
            if (cam.opts.z > 0) gAbs = simd_sum(abs(gXY));
            gXY = simd_sum(gXY);
            gOpacity = simd_sum(gOpacity);
            bool any = simd_any(active);
            if (any && lane == 0) {
                device atomic_float* g = grad2D + sID[k] * GRAD2D_STRIDE;
                atomic_fetch_add_explicit(g + 0, gXY.x, memory_order_relaxed);
                atomic_fetch_add_explicit(g + 1, gXY.y, memory_order_relaxed);
                atomic_fetch_add_explicit(g + 2, gConic.x, memory_order_relaxed);
                atomic_fetch_add_explicit(g + 3, gConic.y, memory_order_relaxed);
                atomic_fetch_add_explicit(g + 4, gConic.z, memory_order_relaxed);
                atomic_fetch_add_explicit(g + 5, gColor.x, memory_order_relaxed);
                atomic_fetch_add_explicit(g + 6, gColor.y, memory_order_relaxed);
                atomic_fetch_add_explicit(g + 7, gColor.z, memory_order_relaxed);
                atomic_fetch_add_explicit(g + 8, gOpacity, memory_order_relaxed);
                if (cam.opts.z > 0) {
                    atomic_fetch_add_explicit(g + 9, gAbs.x, memory_order_relaxed);
                    atomic_fetch_add_explicit(g + 10, gAbs.y, memory_order_relaxed);
                }
            }
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
}

// MARK: - Backward through the projection

kernel void preprocessBackward(device const float4* means [[buffer(0)]],
                               device const float4* logScales [[buffer(1)]],
                               device const float4* quats [[buffer(2)]],
                               device const float4* colorOp [[buffer(3)]],
                               constant CameraParams& cam [[buffer(4)]],
                               device const float4* projXY [[buffer(5)]],
                               device const float* grad2D [[buffer(6)]],
                               device float4* dMean [[buffer(7)]],
                               device float4* dScale [[buffer(8)]],
                               device float4* dQuat [[buffer(9)]],
                               device float4* dColorOp [[buffer(10)]],
                               constant uint& count [[buffer(11)]],
                               constant RegParams& reg [[buffer(12)]],
                               uint i [[thread_position_in_grid]]) {
    if (i >= count) return;
    float4 co = colorOp[i];
    float opacity = sigmoid(co.w);
    float3 s = exp(logScales[i].xyz);
    // Regularisers (MCMC): mean opacity and mean scale, on every Gaussian.
    float dOpLogit = reg.opacity / reg.count * opacity * (1 - opacity);
    float3 dLogScale = reg.scale / (3.0f * reg.count) * s;
    float3 dMean3 = float3(0), dF = float3(0);
    float4 dQ = float4(0);
    if (projXY[i].w > 0) {
        device const float* g = grad2D + i * GRAD2D_STRIDE;
        float2 gXY = float2(g[0], g[1]);
        float3 gConic = float3(g[2], g[3], g[4]);
        float3 gColor = float3(g[5], g[6], g[7]);
        float gOpacity = g[8];
        dOpLogit += gOpacity * opacity * (1 - opacity);
        float3 raw = 0.5f + SH_C0 * co.xyz;
        dF = gColor * SH_C0 * select(float3(0), float3(1), raw > 0);

        Projected p = project(means[i].xyz, logScales[i].xyz, quats[i], cam);
        if (p.valid) {
            float A = p.A, B = p.B, C = p.C, det2 = p.det * p.det;
            float a_ = gConic.x, b_ = gConic.y, c_ = gConic.z;
            float dA = (-a_ * C * C + b_ * B * C - c_ * B * B) / det2;
            float dB = (2 * a_ * B * C - b_ * (p.det + 2 * B * B) + 2 * c_ * A * B) / det2;
            float dC = (-a_ * B * B + b_ * A * B - c_ * A * A) / det2;
            // Σ' = T Σ Tᵀ, rows t0, t1 of T.
            float3x3 G = dA * float3x3(p.t0 * p.t0.x, p.t0 * p.t0.y, p.t0 * p.t0.z)
                       + dB * float3x3(p.t0 * p.t1.x, p.t0 * p.t1.y, p.t0 * p.t1.z)
                       + dC * float3x3(p.t1 * p.t1.x, p.t1 * p.t1.y, p.t1 * p.t1.z);
            float3x3 dM = (G + transpose(G)) * p.M;
            float3 dS = float3(dot(dM[0], p.R[0]), dot(dM[1], p.R[1]), dot(dM[2], p.R[2]));
            dLogScale += dS * p.s;
            float3x3 dR = float3x3(dM[0] * p.s.x, dM[1] * p.s.y, dM[2] * p.s.z);
            // dR[c][r] is ∂L/∂R(r, c).
            float w = p.q.x, x = p.q.y, y = p.q.z, z = p.q.w;
            float g00 = dR[0][0], g01 = dR[1][0], g02 = dR[2][0];
            float g10 = dR[0][1], g11 = dR[1][1], g12 = dR[2][1];
            float g20 = dR[0][2], g21 = dR[1][2], g22 = dR[2][2];
            float4 dq = 2 * float4(-z * g01 + y * g02 + z * g10 - x * g12 - y * g20 + x * g21,
                                   y * g01 + z * g02 + y * g10 - 2 * x * g11 - w * g12 + z * g20 + w * g21 - 2 * x * g22,
                                   -2 * y * g00 + x * g01 + w * g02 + x * g10 + z * g12 - w * g20 + z * g21 - 2 * y * g22,
                                   -2 * z * g00 - w * g01 + x * g02 + w * g10 - 2 * z * g11 + y * g12 + x * g20 + y * g21);
            dQ = (dq - p.q * dot(p.q, dq)) / p.qNorm;
            // Mean: through J (in T) and through the projected centre.
            float3 dt0 = 2 * dA * (p.sigma * p.t0) + dB * (p.sigma * p.t1);
            float3 dt1 = dB * (p.sigma * p.t0) + 2 * dC * (p.sigma * p.t1);
            float dJ00 = dot(dt0, cam.r0.xyz), dJ02 = dot(dt0, cam.r2.xyz);
            float dJ11 = dot(dt1, cam.r1.xyz), dJ12 = dot(dt1, cam.r2.xyz);
            float fx = cam.intr.x, fy = cam.intr.y, invz = 1.0f / p.p.z, invz2 = invz * invz;
            float3 dP = float3(0);
            dP.z += -dJ00 * fx * invz2 - dJ11 * fy * invz2;
            // j02 = -fx·cx/z with cx = x/z unless clamped.
            if (p.clampX) dP.z += dJ02 * fx * p.clampedX * invz2;
            else { dP.x += -dJ02 * fx * invz2; dP.z += dJ02 * 2 * fx * p.p.x * invz2 * invz; }
            if (p.clampY) dP.z += dJ12 * fy * p.clampedY * invz2;
            else { dP.y += -dJ12 * fy * invz2; dP.z += dJ12 * 2 * fy * p.p.y * invz2 * invz; }
            dP.x += gXY.x * fx * invz;
            dP.y += gXY.y * fy * invz;
            dP.z += -gXY.x * fx * p.p.x * invz2 - gXY.y * fy * p.p.y * invz2;
            dMean3 = dP.x * cam.r0.xyz + dP.y * cam.r1.xyz + dP.z * cam.r2.xyz;
        }
    }
    dMean[i] = float4(dMean3, 0);
    dScale[i] = float4(dLogScale, 0);
    dQuat[i] = dQ;
    dColorOp[i] = float4(dF, dOpLogit);
}

// MARK: - Optimiser

inline uint hash(uint x) {
    x ^= x >> 16; x *= 0x7feb352dU; x ^= x >> 15; x *= 0x846ca68bU; x ^= x >> 16;
    return x;
}
inline float uniform01(uint seed) { return (float(hash(seed) >> 8) + 0.5f) / 16777216.0f; }
inline float normal(uint seed) {
    float u1 = uniform01(seed), u2 = uniform01(seed ^ 0x9e3779b9U);
    return sqrt(-2 * log(u1)) * cos(6.2831853f * u2);
}

inline float4 adamStep(device float4& param, device float4& m, device float4& v, float4 g, float4 lr,
                       constant AdamParams& a) {
    float4 mm = a.beta1 * m + (1 - a.beta1) * g;
    float4 vv = a.beta2 * v + (1 - a.beta2) * g * g;
    m = mm; v = vv;
    float4 update = lr * (mm / a.bc1) / (sqrt(vv / a.bc2) + a.epsilon);
    param -= update;
    return param;
}

kernel void adam(device float4* means [[buffer(0)]], device float4* logScales [[buffer(1)]],
                 device float4* quats [[buffer(2)]], device float4* colorOp [[buffer(3)]],
                 device const float4* dMean [[buffer(4)]], device const float4* dScale [[buffer(5)]],
                 device const float4* dQuat [[buffer(6)]], device const float4* dColorOp [[buffer(7)]],
                 device float4* m [[buffer(8)]],   // 4 * count moments, in the order above
                 device float4* v [[buffer(9)]],
                 constant AdamParams& a [[buffer(10)]],
                 constant uint& count [[buffer(11)]],
                 uint i [[thread_position_in_grid]]) {
    if (i >= count) return;
    adamStep(means[i], m[i], v[i], dMean[i], a.lrMean, a);
    adamStep(logScales[i], m[count + i], v[count + i], dScale[i], a.lrScale, a);
    adamStep(quats[i], m[2 * count + i], v[2 * count + i], dQuat[i], a.lrQuat, a);
    adamStep(colorOp[i], m[3 * count + i], v[3 * count + i], dColorOp[i], a.lrColorOp, a);
    if (a._pad > 0) {
        // Limit a long isolated axis, not surface flattening (largest/middle, not largest/min).
        float3 s = logScales[i].xyz;
        uint largest = s.x >= s.y && s.x >= s.z ? 0u : (s.y >= s.z ? 1u : 2u);
        float middle = max(s[(largest + 1u) % 3u], s[(largest + 2u) % 3u]);
        if (s[largest] > middle + a._pad) {
            logScales[i][largest] = middle + a._pad;
            m[count + i][largest] = 0; v[count + i][largest] = 0;
        }
    }
    // MCMC exploration uses covariance, R diag(sigma^2) R^T, not its square root.
    // Using sigma here over-amplifies centimetre-scale points by roughly 100x.
    if (a.noiseScale > 0) {
        float opacity = sigmoid(colorOp[i].w);
        float gate = 1.0f / (1.0f + exp(100.0f * (opacity - 0.005f)));
        if (gate > 1e-4f) {
            float4 q = quats[i];
            float n = length(q);
            if (n > 1e-8f) {
                float3x3 R = quatToMatrix(q / n);
                float3 s = exp(logScales[i].xyz);
                uint seed = hash(i * 9781u + uint(a.step) * 6271u);
                float3 z = float3(normal(seed), normal(seed + 1u), normal(seed + 2u));
                means[i].xyz += a.noiseScale * gate * (R * (s * s * (transpose(R) * z)));
            }
        }
    }
}

// Accumulated over actual training views; persisted alongside parameters and Adam for resume.
struct SubjectCamera { float4 r0,r1,r2,t,intr; };
inline float subjectMask(float3 p, device const SubjectCamera& cam, device const uchar* mask, uint w, uint h) {
    float3 view=float3(dot(cam.r0.xyz,p),dot(cam.r1.xyz,p),dot(cam.r2.xyz,p))+cam.t.xyz;
    if (view.z <= 0.02f) return -1;
    int2 xy=int2(round(float2(view.x,view.y)/view.z*cam.intr.xy+cam.intr.zw));
    if (xy.x<1 || xy.y<1 || xy.x>=int(w)-1 || xy.y>=int(h)-1) return -1;
    uchar value=0;
    for(int y=-1;y<=1;y++) for(int x=-1;x<=1;x++) value=max(value,mask[(xy.y+y)*w+xy.x+x]);
    return float(value)/255.0f;
}
kernel void subjectSupport(device const float4* means [[buffer(0)]], device const float4* scales [[buffer(1)]],
                           device const float4* quats [[buffer(2)]], device const SubjectCamera* cameras [[buffer(3)]],
                           device const uchar* masks [[buffer(4)]], device float4* votes [[buffer(5)]],
                           constant uint4& info [[buffer(6)]], uint i [[thread_position_in_grid]]) {
    if(i>=info.x) return;
    float3 s=exp(scales[i].xyz);
    float3x3 rotation=quatToMatrix(normalize(quats[i]));
    float4 v=0;float3 lower=0,upper=0;
    for(uint c=0;c<info.y;c++) {
        device const uchar* mask=masks+c*info.z*info.w;
        float center=subjectMask(means[i].xyz,cameras[c],mask,info.z,info.w);
        if(center<0) continue;
        v.x+=1;v.y+=center>=0.35f ? 1.0f:0.0f;
        for(uint axis=0;axis<3;axis++) {
            float3 extent=rotation[axis]*(2*s[axis]);
            lower[axis]+=subjectMask(means[i].xyz-extent,cameras[c],mask,info.z,info.w)>=0.25f ? 1.0f:0.0f;
            upper[axis]+=subjectMask(means[i].xyz+extent,cameras[c],mask,info.z,info.w)>=0.25f ? 1.0f:0.0f;
        }
    }
    v.z=min(lower.x,min(lower.y,lower.z));v.w=min(upper.x,min(upper.y,upper.z));
    votes[i]=v;
}

kernel void accumulateDensity(device const float* gradient [[buffer(0)]],
                              device const uint* touched [[buffer(1)]],
                              device float4* stats [[buffer(2)]],
                              constant uint4& info [[buffer(3)]],
                              uint i [[thread_position_in_grid]]) {
    if (i >= info.x || touched[i] == 0) return;
    float2 g = float2(gradient[i * GRAD2D_STRIDE + 9], gradient[i * GRAD2D_STRIDE + 10]);
    float score = length(g * float2(info.yz) * 0.5f);
    if (isfinite(score)) { stats[i].x += score; stats[i].y += 1; }
}
