package codec

import (
	networkingv1 "k8s.io/api/networking/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
)

type flatObjectMeta struct {
	Labels      map[string]string `json:"labels,omitempty"`
	Annotations map[string]string `json:"annotations,omitempty"`
}

func (in *flatObjectMeta) DeepCopyInto(out *flatObjectMeta) {
	if in.Labels != nil {
		in, out := &in.Labels, &out.Labels
		*out = make(map[string]string, len(*in))
		for key, val := range *in {
			(*out)[key] = val
		}
	}
	if in.Annotations != nil {
		in, out := &in.Annotations, &out.Annotations
		*out = make(map[string]string, len(*in))
		for key, val := range *in {
			(*out)[key] = val
		}
	}
}

type flatIngress struct {
	metav1.TypeMeta `json:"-"`
	flatObjectMeta  `json:",inline"`

	// Spec exploded
	DefaultBackend *networkingv1.IngressBackend `json:"defaultBackend,omitempty" protobuf:"bytes,1,opt,name=defaultBackend"`
	TLS            []networkingv1.IngressTLS    `json:"tls,omitempty" protobuf:"bytes,2,rep,name=tls"`
	Rules          []networkingv1.IngressRule   `json:"rules,omitempty" protobuf:"bytes,3,rep,name=rules"`
}

func (f *flatIngress) GetObjectKind() schema.ObjectKind {
	return f.TypeMeta.GetObjectKind()
}

func (f *flatIngress) DeepCopyObject() runtime.Object {
	out := flatIngress{}

	out.TypeMeta = f.TypeMeta
	f.flatObjectMeta.DeepCopyInto(&out.flatObjectMeta)

	out.DefaultBackend = f.DefaultBackend
	if f.TLS != nil {
		in, out := &f.TLS, &out.TLS
		*out = make([]networkingv1.IngressTLS, len(*in))
		for i := range *in {
			(*in)[i].DeepCopyInto(&(*out)[i])
		}
	}
	if f.Rules != nil {
		in, out := &f.Rules, &out.Rules
		*out = make([]networkingv1.IngressRule, len(*in))
		for i := range *in {
			(*in)[i].DeepCopyInto(&(*out)[i])
		}
	}

	return nil
}

func toFlatIngress(ingress *networkingv1.Ingress) *flatIngress {
	return &flatIngress{
		flatObjectMeta: flatObjectMeta{
			Labels:      ingress.Labels,
			Annotations: ingress.Annotations,
		},
		DefaultBackend: ingress.Spec.DefaultBackend,
		TLS:            ingress.Spec.TLS,
		Rules:          ingress.Spec.Rules,
	}
}

func fromFlatIngress(flat *flatIngress) *networkingv1.Ingress {
	return &networkingv1.Ingress{
		ObjectMeta: metav1.ObjectMeta{
			Labels:      flat.Labels,
			Annotations: flat.Annotations,
		},
		Spec: networkingv1.IngressSpec{
			DefaultBackend: flat.DefaultBackend,
			TLS:            flat.TLS,
			Rules:          flat.Rules,
		},
	}
}
