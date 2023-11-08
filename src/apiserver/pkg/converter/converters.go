package converter

import (
	"k8s.io/apimachinery/pkg/runtime"
)

func RegisterConverters(scheme *runtime.Scheme) {
	registerGatewayApiConverters(scheme)
}
