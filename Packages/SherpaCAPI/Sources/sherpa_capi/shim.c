#include <sherpa_capi.h>

// 保持目标可编译；实现全部在 sherpa-onnx / onnxruntime 静态库中。
int sherpa_capi_shim_placeholder(void) { return 0; }
