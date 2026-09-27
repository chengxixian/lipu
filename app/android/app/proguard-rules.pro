# flutter_onnxruntime 的要求：release 构建要保留 ONNX Runtime 的 Java 类，
# 否则 R8 会把它们裁掉，导致 Basic Pitch 扒谱在 release 包里加载模型失败。
-keep class ai.onnxruntime.** { *; }
