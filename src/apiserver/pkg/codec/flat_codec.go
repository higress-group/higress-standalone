package codec

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	networkingv1 "k8s.io/api/networking/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	kjson "sigs.k8s.io/json"
	"sigs.k8s.io/yaml"
)

var (
	v1IngressGvr        = networkingv1.SchemeGroupVersion.WithResource("ingresses")
	v1IngressGvk        = networkingv1.SchemeGroupVersion.WithKind("Ingress")
	v1IngressApiVersion = networkingv1.SchemeGroupVersion.Group + "/" + networkingv1.SchemeGroupVersion.Version

	noApiVersionKindError = fmt.Errorf("the given data doesn't contain APIVersion and Kind data")
	nonFlatResourceError  = fmt.Errorf("the given data doesn't represent a flat resource")
)

func NewFlatAwareCodec(groupResource schema.GroupResource, innerCodec runtime.Codec) runtime.Codec {
	if v1IngressGvr.GroupResource() == groupResource {
		return &flatIngressCodec{groupResource: groupResource, innerCodec: innerCodec}
	}
	return innerCodec
}

type flatIngressCodec struct {
	groupResource schema.GroupResource
	innerCodec    runtime.Codec
}

func (c *flatIngressCodec) Encode(obj runtime.Object, w io.Writer) error {
	ingress, ok := obj.(*networkingv1.Ingress)
	if !ok {
		return c.innerCodec.Encode(obj, w)
	}
	fIngress := toFlatIngress(ingress)
	return encodeFlatResource(fIngress, w)
}

func (c *flatIngressCodec) Identifier() runtime.Identifier {
	return c.innerCodec.Identifier()
}

func (c *flatIngressCodec) Decode(data []byte, defaults *schema.GroupVersionKind, into runtime.Object) (runtime.Object, *schema.GroupVersionKind, error) {
	fIngress := &flatIngress{}
	err := decodeFlatResource(data, fIngress)
	if err != nil {
		if errors.Is(err, nonFlatResourceError) {
			return c.innerCodec.Decode(data, defaults, into)
		}
		return nil, nil, err
	}
	ingress := fromFlatIngress(fIngress)
	ingress.APIVersion = v1IngressApiVersion
	ingress.Kind = v1IngressGvk.Kind
	return ingress, defaults, err
}

func encodeFlatResource(obj interface{}, w io.Writer) error {
	jsonData, err := json.Marshal(obj)
	if err != nil {
		return err
	}
	yamlData, err := yaml.JSONToYAML(jsonData)
	if err != nil {
		return err
	}
	_, err = w.Write(yamlData)
	return err
}

func decodeFlatResource(data []byte, into interface{}) error {
	jsonData, err := yaml.YAMLToJSON(data)
	if err != nil {
		return err
	}
	// Compatible with non-flat K8s YAMLs
	_, err = tryFindApiVersionKind(jsonData)
	if err == nil {
		return nonFlatResourceError
	}
	if err := kjson.UnmarshalCaseSensitivePreserveInts(jsonData, into); err != nil {
		return err
	}
	return nil
}

func tryFindApiVersionKind(data []byte) (*schema.GroupVersionKind, error) {
	findKind := struct {
		// +optional
		APIVersion string `json:"apiVersion,omitempty"`
		// +optional
		Kind string `json:"kind,omitempty"`
	}{}
	if err := json.Unmarshal(data, &findKind); err != nil {
		return nil, err
	}
	if findKind.APIVersion == "" || findKind.Kind == "" {
		return nil, noApiVersionKindError
	}
	gv, err := schema.ParseGroupVersion(findKind.APIVersion)
	if err != nil {
		return nil, err
	}
	return &schema.GroupVersionKind{Group: gv.Group, Version: gv.Version, Kind: findKind.Kind}, nil
}
