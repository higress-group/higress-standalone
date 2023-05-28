package registry

import (
	"fmt"
	"k8s.io/apimachinery/pkg/api/meta"
	"k8s.io/apimachinery/pkg/conversion"
	"k8s.io/apimachinery/pkg/runtime"
	"reflect"
)

func appendItem(v reflect.Value, obj runtime.Object) {
	v.Set(reflect.Append(v, reflect.ValueOf(obj).Elem()))
}

func getListPrt(listObj runtime.Object) (reflect.Value, error) {
	listPtr, err := meta.GetItemsPtr(listObj)
	if err != nil {
		return reflect.Value{}, err
	}
	v, err := conversion.EnforcePtr(listPtr)
	if err != nil || v.Kind() != reflect.Slice {
		return reflect.Value{}, fmt.Errorf("need ptr to slice: %v", err)
	}
	return v, nil
}
