package converter

import (
	"k8s.io/apimachinery/pkg/conversion"
	"k8s.io/apimachinery/pkg/runtime"
	gwapiv1alpha2 "sigs.k8s.io/gateway-api/apis/v1alpha2"
	gwapiv1beta1 "sigs.k8s.io/gateway-api/apis/v1beta1"
)

func registerGatewayApiConverters(scheme *runtime.Scheme) {
	_ = scheme.Converter().RegisterUntypedConversionFunc(&gwapiv1alpha2.GatewayClass{}, &gwapiv1beta1.GatewayClass{},
		func(a, b interface{}, scope conversion.Scope) error {
			*(b.(*gwapiv1beta1.GatewayClass)) = gwapiv1beta1.GatewayClass(*a.(*gwapiv1alpha2.GatewayClass))
			setApiVersion(b, gwapiv1beta1.GroupVersion)
			return nil
		})
	_ = scheme.Converter().RegisterUntypedConversionFunc(&gwapiv1beta1.GatewayClass{}, &gwapiv1alpha2.GatewayClass{},
		func(a, b interface{}, scope conversion.Scope) error {
			*(b.(*gwapiv1alpha2.GatewayClass)) = gwapiv1alpha2.GatewayClass(*a.(*gwapiv1beta1.GatewayClass))
			setApiVersion(b, gwapiv1alpha2.GroupVersion)
			return nil
		})

	_ = scheme.Converter().RegisterUntypedConversionFunc(&gwapiv1alpha2.Gateway{}, &gwapiv1beta1.Gateway{},
		func(a, b interface{}, scope conversion.Scope) error {
			*(b.(*gwapiv1beta1.Gateway)) = gwapiv1beta1.Gateway(*a.(*gwapiv1alpha2.Gateway))
			setApiVersion(b, gwapiv1beta1.GroupVersion)
			return nil
		})
	_ = scheme.Converter().RegisterUntypedConversionFunc(&gwapiv1beta1.Gateway{}, &gwapiv1alpha2.Gateway{},
		func(a, b interface{}, scope conversion.Scope) error {
			*(b.(*gwapiv1alpha2.Gateway)) = gwapiv1alpha2.Gateway(*a.(*gwapiv1beta1.Gateway))
			setApiVersion(b, gwapiv1alpha2.GroupVersion)
			return nil
		})

	_ = scheme.Converter().RegisterUntypedConversionFunc(&gwapiv1alpha2.HTTPRoute{}, &gwapiv1beta1.HTTPRoute{},
		func(a, b interface{}, scope conversion.Scope) error {
			*(b.(*gwapiv1beta1.HTTPRoute)) = gwapiv1beta1.HTTPRoute(*a.(*gwapiv1alpha2.HTTPRoute))
			setApiVersion(b, gwapiv1beta1.GroupVersion)
			return nil
		})
	_ = scheme.Converter().RegisterUntypedConversionFunc(&gwapiv1beta1.HTTPRoute{}, &gwapiv1alpha2.HTTPRoute{},
		func(a, b interface{}, scope conversion.Scope) error {
			*(b.(*gwapiv1alpha2.HTTPRoute)) = gwapiv1alpha2.HTTPRoute(*a.(*gwapiv1beta1.HTTPRoute))
			setApiVersion(b, gwapiv1alpha2.GroupVersion)
			return nil
		})

	_ = scheme.Converter().RegisterUntypedConversionFunc(&gwapiv1alpha2.ReferenceGrant{}, &gwapiv1beta1.ReferenceGrant{},
		func(a, b interface{}, scope conversion.Scope) error {
			*(b.(*gwapiv1beta1.ReferenceGrant)) = gwapiv1beta1.ReferenceGrant(*a.(*gwapiv1alpha2.ReferenceGrant))
			setApiVersion(b, gwapiv1beta1.GroupVersion)
			return nil
		})
	_ = scheme.Converter().RegisterUntypedConversionFunc(&gwapiv1beta1.ReferenceGrant{}, &gwapiv1alpha2.ReferenceGrant{},
		func(a, b interface{}, scope conversion.Scope) error {
			*(b.(*gwapiv1alpha2.ReferenceGrant)) = gwapiv1alpha2.ReferenceGrant(*a.(*gwapiv1beta1.ReferenceGrant))
			setApiVersion(b, gwapiv1alpha2.GroupVersion)
			return nil
		})
}
