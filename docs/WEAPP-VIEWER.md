# 微信原生 Gaussian Splat 预览模块

实现位置：`miniprogram/lib/splat-renderer.js` 与 `miniprogram/pages/viewer/`。玩家入口为原生 WXML `<canvas type="webgl">`，不使用 HTML、WebView 或网页查看器。

## 接入与真实来源

场景详情跳转 `/pages/viewer/viewer?assetId=<UUID>&sessionId=<UUID>`。页面先校验会话资产对应关系，再通过现有用户 Bearer 认证 API 获取：

1. `GET /v1/assets/:id/viewer-info`：点数、原始资产哈希、派生文件哈希和来源。
2. `GET /v1/assets/:id/viewer`：手机预览专用 `.splat`，默认预算 60,000 点，硬上限 100,000 点。

调用统一 `lib/api.js` 的 `get(path)` 与 `download(path,destFile)`；后者返回实际本地路径。文件放在微信小程序私有目录，解析后即删除；中途失败、离开页面也清理。原始资产仍由服务器保存。页面保留会话与资产 ID，不能把其他会话模型当作本次采集结果。

点数预算仅为第一轮性能试验的初始值，不是任何 iPhone 上流畅的保证。缩减点数和 SH0 颜色是有损显示派生，不应作为训练原件导出。信息中的 SHA256 用于来源记录；页面校验字节数和各字段有效性，不声称已在客户端重新计算整文件 SHA256。

## 渲染方法

标准 `.splat` 每点 32 字节：小端 Float32 位置 xyz、**线性**尺寸 xyz、RGBA8、量化 quaternion **wxyz**。旋转分量还原为 `(byte-128)/128` 后归一化，协方差为 `R diag(scale²) Rᵀ`。

解析后的显示副本以可见点包围球中心平移并按半径归一化，减少大坐标的 GPU 精度损失；原始坐标和半径仍返回为元数据，源文件不被修改。完全透明的离群点不影响初始取景。每点传入位置、6 个协方差元素与 RGBA。WebGL1 `ANGLE_instanced_arrays` 绘制 3σ 四边形，不需要浮点纹理扩展。

顶点着色器对协方差应用相机旋转及透视 Jacobian，得到二维椭圆主轴。片元着色器计算 `alpha × exp(-0.5 × r²)`；CPU 按相机深度由远到近排序，预乘颜色用 `ONE, ONE_MINUS_SRC_ALPHA` 混合。关闭深度写入，避免普通不透明点云的遮挡错误。二维协方差增加 0.3 像素方差，极端近景单轴标准差限制为 512 像素，3σ 外与小于 1/255 的透明度舍弃。这些是显示性能取舍，不是数据质量分数。

支持单指绕中心旋转、双指缩放、恢复完整视角、上下翻转。触摸绘制合并到原生 Canvas 下一帧，不在静止时连续绘制。设备像素比最高取 2，近裁剪面之后的点才绘制。此 MVP 未实现平移、漫游、碰撞、相机标定、机器人可通行性或视角相关高阶 SH。

## 生命周期与计数

隐藏页面暂停绘制；恢复页面重新绘制。卸载时取消原生帧回调、释放 GPU buffer/program/shader、断开场景数组。缺少 WebGL 或实例扩展、着色器编译失败、文件非法、上下文丢失及绘制错误均显示明确错误，不回退到虚构示例。

只有首帧实际 `drawArraysInstancedANGLE` 后，`gl.finish()` 完成且 `gl.getError()` 无错误，才触发 `onReady` 和 `store.log('result_viewed', ...)`。这是图形 API 完成检查，仍不能替代人眼确认真机画面、实际帧率或高质量重建验收。下载成功不计入结果查看；同一页面重试不重复计数。

## 验证

`node --test miniprogram-tests/viewer.test.cjs`

测试包括协方差与旋转约定、解析/归一化、非法文件、相机与排序、透视投影、实例绘制调用及混合设置、首帧事件、GPU 失败不得记成功、隐藏/卸载释放、页面会话资产绑定。WebGL mock 只证明调用顺序与错误传播；不能证明驱动着色器编译和 iPhone 显示。

首次真机测试须记录 iPhone 型号、iOS/微信版本、真实资产 ID/哈希、点数、文件体积、首帧时延、交互表现、两指缩放、后台切回、连续打开/退出十次的内存趋势，以及断网/删除资产后的错误页。至少各打开一份真实室内和室外结果；只有这些记录完成后才能写“真机查看已验证”。如有性能问题先降低服务端显示预算并重复相同测试。人工处理结果回传仍是闭环的一部分；此模块不会自动把普通视频重建为 3DGS。

## 官方 API 与参考来源

- 微信官方 API typings：[`wechat-miniprogram/api-typings`](https://github.com/wechat-miniprogram/api-typings)，研究时 npm `miniprogram-api-typings` 版本 5.2.3。其 `types/wx/lib.wx.api.d.ts` 包含 `Canvas.getContext('webgl')`、原生 Canvas `requestAnimationFrame/cancelAnimationFrame`、SelectorQuery `fields({node:true,size:true})`；`lib.wx.canvas.d.ts` 定义原生 WebGL 接口。API 类型存在不等于目标手机测试通过。
- 微信官方 Canvas 文档：[Canvas](https://developers.weixin.qq.com/miniprogram/dev/api/canvas/Canvas.html)。研究时官方网页访问不可用，以上官方包用于核对；实际能力仍由开发者工具与 iPhone 验证。
- 数学与混合实现参考 [antimatter15/splat](https://github.com/antimatter15/splat)，核对提交 `ba182b51b7c2ad5738cdd6741cd63336d27470fb`。本模块使用本地属性 buffer 与 WebGL1 原生 Canvas，未复制其 DOM、Web Worker 或网页入口。

参考项目 MIT 许可证如下，保留于派生模块发布文档：

```text
MIT License

Copyright (c) 2023 Kevin Kwok

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
