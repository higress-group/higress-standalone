package converter

import (
	"k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

func setApiVersion(obj interface{}, groupVersion metav1.GroupVersion) {
	if typeAccessor, err := meta.TypeAccessor(obj); err == nil {
		typeAccessor.SetAPIVersion(groupVersion.String())
	}
}
