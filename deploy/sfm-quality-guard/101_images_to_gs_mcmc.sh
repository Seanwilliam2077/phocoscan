#!/usr/bin/env bash
# Full Branch-A path on a new box: images → COLMAP 4 SfM → gsplat 3DGS-MCMC.
#
# Usage:
#   SEQ=/path/to/sequence IMAGES=/path/to/photos bash scripts/101_images_to_gs_mcmc.sh
#
# SEQ is created if missing. Images are symlinked into ${WORK}/images.
# MCMC requires PINHOLE or SIMPLE_PINHOLE (fisheye / SIMPLE_RADIAL will be rejected).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${ROOT:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
SEQ="${SEQ:?set SEQ to the sequence/output directory}"
IMAGES="${IMAGES:-${SEQ}/images}"
WORK="${WORK:-${SEQ}/sfm_images}"
COLMAP="${COLMAP:-${HOME}/miniconda3/envs/colmap4/bin/colmap}"
if [ ! -x "${COLMAP}" ]; then
  COLMAP="/home/wang/miniconda3/envs/colmap4/bin/colmap"
fi
CAMERA_MODEL="${CAMERA_MODEL:-SIMPLE_PINHOLE}"
CAMERA_PARAMS="${CAMERA_PARAMS:-}"          # PINHOLE: fx,fy,cx,cy ; SIMPLE_PINHOLE: fx,cx,cy
MATCHER="${MATCHER:-exhaustive}"            # sequential | exhaustive
WINDOW="${SEQ_WINDOW:-15}"
PEAK_THRESHOLD="${SIFT_PEAK_THRESHOLD:-0.00667}"
SKIP_SFM="${SKIP_SFM:-0}"
SKIP_MCMC="${SKIP_MCMC:-0}"
POSE_PRIOR_CSV="${POSE_PRIOR_CSV:-}"
# 非空即 mask 路线：目录里放的是 <照片文件名>.png（白=保留）。COLMAP 按
# ImageReader.mask_path 约定找 `<image_name>.png`，所以这里直接指到准备阶段
# 写好的 masks 目录，不做二次改名。
MASK_DIR="${MASK_DIR:-}"
COLMAP_PYTHON="${COLMAP_PYTHON:-$(dirname "${COLMAP}")/python}"
# COLMAP expects a physical GPU index, while CUDA_VISIBLE_DEVICES renumbers a
# single exposed card to logical index 0. Keep them separate so Hub workers can
# safely lease GPU 1..N.
GPU_INDEX="${GPU_INDEX:-${CUDA_VISIBLE_DEVICES:-0}}"
unset CUDA_VISIBLE_DEVICES

if [ ! -x "${COLMAP}" ]; then
  echo "ERROR: COLMAP 4 binary not found. Install conda env colmap4 (see docs/GS_MCMC_A10_部署指南.md §4)." >&2
  exit 1
fi
if [ ! -d "${IMAGES}" ]; then
  echo "ERROR: IMAGES directory missing: ${IMAGES}" >&2
  exit 1
fi
case "${CAMERA_MODEL}" in
  PINHOLE|SIMPLE_PINHOLE) ;;
  *)
    echo "ERROR: CAMERA_MODEL=${CAMERA_MODEL} is not usable by gsplat MCMC. Use PINHOLE or SIMPLE_PINHOLE." >&2
    exit 1
    ;;
esac

mkdir -p "${SEQ}" "${WORK}"
rm -rf "${WORK}/images"
ln -sfn "$(realpath "${IMAGES}")" "${WORK}/images"

if [ -n "${MASK_DIR}" ]; then
  if [ ! -d "${MASK_DIR}" ]; then
    echo "ERROR: MASK_DIR is set but missing: ${MASK_DIR}" >&2
    exit 1
  fi
  MASK_N=$(find "${MASK_DIR}" -maxdepth 1 -type f -name '*.png' | wc -l)
  IMG_N=$(find "${IMAGES}" -maxdepth 1 -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.webp' \) | wc -l)
  echo "=== mask route: ${MASK_N} mask(s) for ${IMG_N} image(s) in ${MASK_DIR} ==="
  if [ "${MASK_N}" -eq 0 ]; then
    echo "ERROR: MASK_DIR has no *.png masks" >&2
    exit 1
  fi
  # COLMAP 拿不到 <照片文件名>.png 时会把那张照片整个剔除，没有"忽略缺失 mask"的开关。
  # 准备阶段会给未标注的照片补全白 mask，所以数字不等只可能是数据集在补白之前准备的。
  if [ "${MASK_N}" -lt "${IMG_N}" ]; then
    echo "WARNING: ${MASK_N} mask(s) < ${IMG_N} image(s) —— COLMAP 会把 $((IMG_N - MASK_N)) 张" \
         "拿不到 mask 的照片整张剔除(MASK_ERROR)，本次重建只会有 ${MASK_N} 张照片参与。" \
         "重新准备数据即可修复。" >&2
  fi
fi

if [ "${SKIP_SFM}" != "1" ]; then
  echo "=== [101/1] COLMAP feature_extractor ==="
  rm -f "${WORK}/database.db"
  rm -rf "${WORK}/sparse"
  STABLE_FEATURE_ARGS=()
  STABLE_MATCH_ARGS=()
  if [ -z "${POSE_PRIOR_CSV}" ]; then
    "${COLMAP_PYTHON}" "${SCRIPT_DIR}/104_sfm_quality_guard.py" list \
      --images "${WORK}/images" --output "${WORK}/sfm-image-order.txt"
    STABLE_FEATURE_ARGS=(--image_list_path "${WORK}/sfm-image-order.txt" --FeatureExtraction.num_threads 1 --default_random_seed 0)
    STABLE_MATCH_ARGS=(--FeatureMatching.num_threads 1 --TwoViewGeometry.random_seed 0 --default_random_seed 0)
  fi
  FEAT=(
    "${COLMAP}" feature_extractor
    --database_path "${WORK}/database.db"
    --image_path "${WORK}/images"
    --ImageReader.camera_model "${CAMERA_MODEL}"
    --ImageReader.single_camera 1
    --FeatureExtraction.use_gpu 1
    --FeatureExtraction.gpu_index "${GPU_INDEX}"
    --SiftExtraction.estimate_affine_shape 1
    --SiftExtraction.domain_size_pooling 1
    --SiftExtraction.peak_threshold "${PEAK_THRESHOLD}"
    "${STABLE_FEATURE_ARGS[@]}"
  )
  if [ -n "${CAMERA_PARAMS}" ]; then
    FEAT+=(--ImageReader.camera_params "${CAMERA_PARAMS}")
  fi
  if [ -n "${MASK_DIR}" ]; then
    # 黑像素处不提特征：人/动态物不再参与匹配与三角化。
    FEAT+=(--ImageReader.mask_path "${MASK_DIR}")
  fi
  "${FEAT[@]}"

  echo "=== [101/2] ${MATCHER} matcher ==="
  if [ "${MATCHER}" = "exhaustive" ]; then
    "${COLMAP}" exhaustive_matcher \
      --database_path "${WORK}/database.db" \
      --FeatureMatching.use_gpu 1 \
      --FeatureMatching.gpu_index "${GPU_INDEX}" \
      "${STABLE_MATCH_ARGS[@]}"
  else
    "${COLMAP}" sequential_matcher \
      --database_path "${WORK}/database.db" \
      --SequentialMatching.overlap "${WINDOW}" \
      --SequentialMatching.quadratic_overlap 1 \
      --FeatureMatching.use_gpu 1 \
      --FeatureMatching.gpu_index "${GPU_INDEX}" \
      "${STABLE_MATCH_ARGS[@]}"
  fi

  mkdir -p "${WORK}/sparse"
  MAPPER_REFINE_FOCAL=1
  MAPPER_REFINE_PP=0
  if [ -n "${CAMERA_PARAMS}" ]; then
    MAPPER_REFINE_FOCAL=0
  fi
  MAPPER_BIN=mapper
  if [ -n "${POSE_PRIOR_CSV}" ]; then
    if [ ! -f "${POSE_PRIOR_CSV}" ]; then
      echo "ERROR: POSE_PRIOR_CSV is set but missing: ${POSE_PRIOR_CSV}" >&2
      exit 1
    fi
    if [ ! -x "${COLMAP_PYTHON}" ]; then
      echo "ERROR: COLMAP_PYTHON not executable: ${COLMAP_PYTHON}" >&2
      exit 1
    fi
    echo "=== [101/2.5] write COLMAP pose priors from ${POSE_PRIOR_CSV} ==="
    "${COLMAP_PYTHON}" "${SCRIPT_DIR}/103_write_colmap_pose_priors.py" \
      --database "${WORK}/database.db" \
      --prior-csv "${POSE_PRIOR_CSV}" \
      --report "${WORK}/pose_prior_write.json"
    MAPPER_BIN=pose_prior_mapper
    echo "=== [101/3] ${MAPPER_BIN} (soft position priors + BA, not fixed poses) ==="
  else
    echo "=== [101/3] ${MAPPER_BIN} (pure visual incremental SfM + BA) ==="
  fi
  MAPPER_ARGS=(
    "${COLMAP}" "${MAPPER_BIN}"
    --database_path "${WORK}/database.db"
    --image_path "${WORK}/images"
    --output_path "${WORK}/sparse"
    --Mapper.ba_refine_focal_length "${MAPPER_REFINE_FOCAL}"
    --Mapper.ba_refine_principal_point "${MAPPER_REFINE_PP}"
    --Mapper.ba_refine_extra_params 0
    --Mapper.multiple_models 0
    --Mapper.min_num_matches 15
    --Mapper.init_min_tri_angle 4
    --Mapper.abs_pose_max_error 12
    --Mapper.filter_max_reproj_error 4
  )
  if [ "${MAPPER_BIN}" = "pose_prior_mapper" ]; then
    MAPPER_ARGS+=(
      --use_robust_loss_on_prior_position 1
      --overwrite_priors_covariance 0
    )
  fi
  if [ "${MAPPER_BIN}" = "mapper" ]; then
    "${COLMAP_PYTHON}" "${SCRIPT_DIR}/104_sfm_quality_guard.py" map \
      --database "${WORK}/database.db" --output "${WORK}/sparse" -- "${MAPPER_ARGS[@]}"
  else
    "${MAPPER_ARGS[@]}"
  fi

  if [ ! -d "${WORK}/sparse/0" ]; then
    echo "ERROR: SfM produced no sparse/0. Check registration (try MATCHER=exhaustive or lower SIFT_PEAK_THRESHOLD=0.002)." >&2
    exit 1
  fi
  "${COLMAP}" model_analyzer --path "${WORK}/sparse/0" || true
  echo "=== SfM done: ${WORK}/sparse/0 ==="
else
  echo "=== skip SfM (SKIP_SFM=1) ==="
  [ -d "${WORK}/sparse/0" ] || { echo "ERROR: ${WORK}/sparse/0 missing"; exit 1; }
fi

if [ "${SKIP_MCMC}" = "1" ]; then
  echo "SKIP_MCMC=1; not launching training."
  exit 0
fi

echo "=== [101/4] gsplat 3DGS-MCMC ==="
export ROOT
export GSPLAT_ROOT="${GSPLAT_ROOT:-${ROOT}}"
export SEQ
export WORK
export SPARSE_DIR="${WORK}/sparse/0"
export IMAGES_DIR="${WORK}/images"
export CUDA_VISIBLE_DEVICES="${GPU_INDEX}"
export CUDA_VISIBLE_DEVICES
export SKIP_EVAL="${SKIP_EVAL:-1}"
export MASK_DIR
bash "${SCRIPT_DIR}/100_run_gs_mcmc.sh"
