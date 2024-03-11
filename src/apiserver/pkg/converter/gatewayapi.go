package converter

import (
	"k8s.io/apimachinery/pkg/conversion"
	"k8s.io/apimachinery/pkg/runtime"
	gwapiv1alpha2 "sigs.k8s.io/gateway-api/apis/v1alpha2"
	gwapiv1beta1 "sigs.k8s.io/gateway-api/apis/v1beta1"

	gwapiv1 "github.com/alibaba/higress/api-server/pkg/apis/gatewayapi/v1"
)

func registerGatewayApiConverters(scheme *runtime.Scheme) {
	registerGatewayApiConvertersV1ToV1beta1(scheme)
	registerGatewayApiConvertersV1ToV1alpha2(scheme)
	registerGatewayApiConvertersV1beta1ToV1(scheme)
	registerGatewayApiConvertersV1beta1ToV1alpha2(scheme)
	registerGatewayApiConvertersV1alpha2ToV1(scheme)
	registerGatewayApiConvertersV1alpha2ToV1beta1(scheme)
}

func registerGatewayApiConvertersV1ToV1beta1(scheme *runtime.Scheme) {
	_ = scheme.Converter().RegisterUntypedConversionFunc(&gwapiv1.GatewayClassList{}, &gwapiv1beta1.GatewayClassList{},
		func(a, b interface{}, scope conversion.Scope) error {
			lb := b.(*gwapiv1beta1.GatewayClassList)
			la := a.(*gwapiv1.GatewayClassList)
			lb.Items = make([]gwapiv1beta1.GatewayClass, len(la.Items))
			for i := range la.Items {
				if err := scheme.Convert(&la.Items[i], &lb.Items[i], scope); err != nil {
					return err
				}
			}
			setApiVersion(b, gwapiv1beta1.GroupVersion)
			return nil
		})
	_ = scheme.Converter().RegisterUntypedConversionFunc(&gwapiv1.GatewayClass{}, &gwapiv1beta1.GatewayClass{},
		func(a, b interface{}, scope conversion.Scope) error {
			*(b.(*gwapiv1beta1.GatewayClass)) = gwapiv1beta1.GatewayClass(*a.(*gwapiv1.GatewayClass))
			setApiVersion(b, gwapiv1beta1.GroupVersion)
			return nil
		})
	_ = scheme.Converter().RegisterUntypedConversionFunc(&gwapiv1.GatewayList{}, &gwapiv1beta1.GatewayList{},
		func(a, b interface{}, scope conversion.Scope) error {
			lb := b.(*gwapiv1beta1.GatewayList)
			la := a.(*gwapiv1.GatewayList)
			lb.Items = make([]gwapiv1beta1.Gateway, len(la.Items))
			for i := range la.Items {
				if err := scheme.Convert(&la.Items[i], &lb.Items[i], scope); err != nil {
					return err
				}
			}
			setApiVersion(b, gwapiv1beta1.GroupVersion)
			return nil
		})
	_ = scheme.Converter().RegisterUntypedConversionFunc(&gwapiv1.Gateway{}, &gwapiv1beta1.Gateway{},
		func(a, b interface{}, scope conversion.Scope) error {
			*(b.(*gwapiv1beta1.Gateway)) = gwapiv1beta1.Gateway(*a.(*gwapiv1.Gateway))
			setApiVersion(b, gwapiv1beta1.GroupVersion)
			return nil
		})
	_ = scheme.Converter().RegisterUntypedConversionFunc(&gwapiv1.HTTPRouteList{}, &gwapiv1beta1.HTTPRouteList{},
		func(a, b interface{}, scope conversion.Scope) error {
			lb := b.(*gwapiv1beta1.HTTPRouteList)
			la := a.(*gwapiv1.HTTPRouteList)
			lb.Items = make([]gwapiv1beta1.HTTPRoute, len(la.Items))
			for i := range la.Items {
				if err := scheme.Convert(&la.Items[i], &lb.Items[i], scope); err != nil {
					return err
				}
			}
			setApiVersion(b, gwapiv1beta1.GroupVersion)
			return nil
		})
	_ = scheme.Converter().RegisterUntypedConversionFunc(&gwapiv1.HTTPRoute{}, &gwapiv1beta1.HTTPRoute{},
		func(a, b interface{}, scope conversion.Scope) error {
			*(b.(*gwapiv1beta1.HTTPRoute)) = gwapiv1beta1.HTTPRoute(*a.(*gwapiv1.HTTPRoute))
			setApiVersion(b, gwapiv1beta1.GroupVersion)
			return nil
		})
}

func registerGatewayApiConvertersV1ToV1alpha2(scheme *runtime.Scheme) {
	_ = scheme.Converter().RegisterUntypedConversionFunc(&gwapiv1.GatewayClassList{}, &gwapiv1alpha2.GatewayClassList{},
		func(a, b interface{}, scope conversion.Scope) error {
			lb := b.(*gwapiv1alpha2.GatewayClassList)
			la := a.(*gwapiv1.GatewayClassList)
			lb.Items = make([]gwapiv1alpha2.GatewayClass, len(la.Items))
			for i := range la.Items {
				if err := scheme.Convert(&la.Items[i], &lb.Items[i], scope); err != nil {
					return err
				}
			}
			setApiVersion(b, gwapiv1alpha2.GroupVersion)
			return nil
		})
	_ = scheme.Converter().RegisterUntypedConversionFunc(&gwapiv1.GatewayClass{}, &gwapiv1alpha2.GatewayClass{},
		func(a, b interface{}, scope conversion.Scope) error {
			*(b.(*gwapiv1alpha2.GatewayClass)) = gwapiv1alpha2.GatewayClass(*a.(*gwapiv1.GatewayClass))
			setApiVersion(b, gwapiv1alpha2.GroupVersion)
			return nil
		})
	_ = scheme.Converter().RegisterUntypedConversionFunc(&gwapiv1.GatewayList{}, &gwapiv1alpha2.GatewayList{},
		func(a, b interface{}, scope conversion.Scope) error {
			lb := b.(*gwapiv1alpha2.GatewayList)
			la := a.(*gwapiv1.GatewayList)
			lb.Items = make([]gwapiv1alpha2.Gateway, len(la.Items))
			for i := range la.Items {
				if err := scheme.Convert(&la.Items[i], &lb.Items[i], scope); err != nil {
					return err
				}
			}
			setApiVersion(b, gwapiv1alpha2.GroupVersion)
			return nil
		})
	_ = scheme.Converter().RegisterUntypedConversionFunc(&gwapiv1.Gateway{}, &gwapiv1alpha2.Gateway{},
		func(a, b interface{}, scope conversion.Scope) error {
			*(b.(*gwapiv1alpha2.Gateway)) = gwapiv1alpha2.Gateway(*a.(*gwapiv1.Gateway))
			setApiVersion(b, gwapiv1alpha2.GroupVersion)
			return nil
		})
	_ = scheme.Converter().RegisterUntypedConversionFunc(&gwapiv1.HTTPRouteList{}, &gwapiv1alpha2.HTTPRouteList{},
		func(a, b interface{}, scope conversion.Scope) error {
			lb := b.(*gwapiv1alpha2.HTTPRouteList)
			la := a.(*gwapiv1.HTTPRouteList)
			lb.Items = make([]gwapiv1alpha2.HTTPRoute, len(la.Items))
			for i := range la.Items {
				if err := scheme.Convert(&la.Items[i], &lb.Items[i], scope); err != nil {
					return err
				}
			}
			setApiVersion(b, gwapiv1alpha2.GroupVersion)
			return nil
		})
	_ = scheme.Converter().RegisterUntypedConversionFunc(&gwapiv1.HTTPRoute{}, &gwapiv1alpha2.HTTPRoute{},
		func(a, b interface{}, scope conversion.Scope) error {
			*(b.(*gwapiv1alpha2.HTTPRoute)) = gwapiv1alpha2.HTTPRoute(*a.(*gwapiv1.HTTPRoute))
			setApiVersion(b, gwapiv1alpha2.GroupVersion)
			return nil
		})
}

func registerGatewayApiConvertersV1beta1ToV1(scheme *runtime.Scheme) {
	_ = scheme.Converter().RegisterUntypedConversionFunc(&gwapiv1beta1.GatewayClassList{}, &gwapiv1.GatewayClassList{},
		func(a, b interface{}, scope conversion.Scope) error {
			lb := b.(*gwapiv1.GatewayClassList)
			la := a.(*gwapiv1beta1.GatewayClassList)
			lb.Items = make([]gwapiv1.GatewayClass, len(la.Items))
			for i := range la.Items {
				if err := scheme.Convert(&la.Items[i], &lb.Items[i], scope); err != nil {
					return err
				}
			}
			setApiVersion(b, gwapiv1.GroupVersion)
			return nil
		})
	_ = scheme.Converter().RegisterUntypedConversionFunc(&gwapiv1beta1.GatewayClass{}, &gwapiv1.GatewayClass{},
		func(a, b interface{}, scope conversion.Scope) error {
			*(b.(*gwapiv1.GatewayClass)) = gwapiv1.GatewayClass(*a.(*gwapiv1beta1.GatewayClass))
			setApiVersion(b, gwapiv1.GroupVersion)
			return nil
		})
	_ = scheme.Converter().RegisterUntypedConversionFunc(&gwapiv1beta1.GatewayList{}, &gwapiv1.GatewayList{},
		func(a, b interface{}, scope conversion.Scope) error {
			lb := b.(*gwapiv1.GatewayList)
			la := a.(*gwapiv1beta1.GatewayList)
			lb.Items = make([]gwapiv1.Gateway, len(la.Items))
			for i := range la.Items {
				if err := scheme.Convert(&la.Items[i], &lb.Items[i], scope); err != nil {
					return err
				}
			}
			setApiVersion(b, gwapiv1.GroupVersion)
			return nil
		})
	_ = scheme.Converter().RegisterUntypedConversionFunc(&gwapiv1beta1.Gateway{}, &gwapiv1.Gateway{},
		func(a, b interface{}, scope conversion.Scope) error {
			*(b.(*gwapiv1.Gateway)) = gwapiv1.Gateway(*a.(*gwapiv1beta1.Gateway))
			setApiVersion(b, gwapiv1.GroupVersion)
			return nil
		})
	_ = scheme.Converter().RegisterUntypedConversionFunc(&gwapiv1beta1.HTTPRouteList{}, &gwapiv1.HTTPRouteList{},
		func(a, b interface{}, scope conversion.Scope) error {
			lb := b.(*gwapiv1.HTTPRouteList)
			la := a.(*gwapiv1beta1.HTTPRouteList)
			lb.Items = make([]gwapiv1.HTTPRoute, len(la.Items))
			for i := range la.Items {
				if err := scheme.Convert(&la.Items[i], &lb.Items[i], scope); err != nil {
					return err
				}
			}
			setApiVersion(b, gwapiv1.GroupVersion)
			return nil
		})
	_ = scheme.Converter().RegisterUntypedConversionFunc(&gwapiv1beta1.HTTPRoute{}, &gwapiv1.HTTPRoute{},
		func(a, b interface{}, scope conversion.Scope) error {
			*(b.(*gwapiv1.HTTPRoute)) = gwapiv1.HTTPRoute(*a.(*gwapiv1beta1.HTTPRoute))
			setApiVersion(b, gwapiv1.GroupVersion)
			return nil
		})
}

func registerGatewayApiConvertersV1beta1ToV1alpha2(scheme *runtime.Scheme) {
	_ = scheme.Converter().RegisterUntypedConversionFunc(&gwapiv1beta1.GatewayClassList{}, &gwapiv1alpha2.GatewayClassList{},
		func(a, b interface{}, scope conversion.Scope) error {
			lb := b.(*gwapiv1alpha2.GatewayClassList)
			la := a.(*gwapiv1beta1.GatewayClassList)
			lb.Items = make([]gwapiv1alpha2.GatewayClass, len(la.Items))
			for i := range la.Items {
				if err := scheme.Convert(&la.Items[i], &lb.Items[i], scope); err != nil {
					return err
				}
			}
			setApiVersion(b, gwapiv1alpha2.GroupVersion)
			return nil
		})
	_ = scheme.Converter().RegisterUntypedConversionFunc(&gwapiv1beta1.GatewayClass{}, &gwapiv1alpha2.GatewayClass{},
		func(a, b interface{}, scope conversion.Scope) error {
			*(b.(*gwapiv1alpha2.GatewayClass)) = gwapiv1alpha2.GatewayClass(*a.(*gwapiv1beta1.GatewayClass))
			setApiVersion(b, gwapiv1alpha2.GroupVersion)
			return nil
		})
	_ = scheme.Converter().RegisterUntypedConversionFunc(&gwapiv1beta1.GatewayList{}, &gwapiv1alpha2.GatewayList{},
		func(a, b interface{}, scope conversion.Scope) error {
			lb := b.(*gwapiv1alpha2.GatewayList)
			la := a.(*gwapiv1beta1.GatewayList)
			lb.Items = make([]gwapiv1alpha2.Gateway, len(la.Items))
			for i := range la.Items {
				if err := scheme.Convert(&la.Items[i], &lb.Items[i], scope); err != nil {
					return err
				}
			}
			setApiVersion(b, gwapiv1alpha2.GroupVersion)
			return nil
		})
	_ = scheme.Converter().RegisterUntypedConversionFunc(&gwapiv1beta1.Gateway{}, &gwapiv1alpha2.Gateway{},
		func(a, b interface{}, scope conversion.Scope) error {
			*(b.(*gwapiv1alpha2.Gateway)) = gwapiv1alpha2.Gateway(*a.(*gwapiv1beta1.Gateway))
			setApiVersion(b, gwapiv1alpha2.GroupVersion)
			return nil
		})
	_ = scheme.Converter().RegisterUntypedConversionFunc(&gwapiv1beta1.HTTPRouteList{}, &gwapiv1alpha2.HTTPRouteList{},
		func(a, b interface{}, scope conversion.Scope) error {
			lb := b.(*gwapiv1alpha2.HTTPRouteList)
			la := a.(*gwapiv1beta1.HTTPRouteList)
			lb.Items = make([]gwapiv1alpha2.HTTPRoute, len(la.Items))
			for i := range la.Items {
				if err := scheme.Convert(&la.Items[i], &lb.Items[i], scope); err != nil {
					return err
				}
			}
			setApiVersion(b, gwapiv1alpha2.GroupVersion)
			return nil
		})
	_ = scheme.Converter().RegisterUntypedConversionFunc(&gwapiv1beta1.HTTPRoute{}, &gwapiv1alpha2.HTTPRoute{},
		func(a, b interface{}, scope conversion.Scope) error {
			*(b.(*gwapiv1alpha2.HTTPRoute)) = gwapiv1alpha2.HTTPRoute(*a.(*gwapiv1beta1.HTTPRoute))
			setApiVersion(b, gwapiv1alpha2.GroupVersion)
			return nil
		})
	_ = scheme.Converter().RegisterUntypedConversionFunc(&gwapiv1beta1.ReferenceGrant{}, &gwapiv1alpha2.ReferenceGrant{},
		func(a, b interface{}, scope conversion.Scope) error {
			*(b.(*gwapiv1alpha2.ReferenceGrant)) = gwapiv1alpha2.ReferenceGrant(*a.(*gwapiv1beta1.ReferenceGrant))
			setApiVersion(b, gwapiv1alpha2.GroupVersion)
			return nil
		})
	_ = scheme.Converter().RegisterUntypedConversionFunc(&gwapiv1beta1.ReferenceGrantList{}, &gwapiv1alpha2.ReferenceGrantList{},
		func(a, b interface{}, scope conversion.Scope) error {
			lb := b.(*gwapiv1alpha2.ReferenceGrantList)
			la := a.(*gwapiv1beta1.ReferenceGrantList)
			lb.Items = make([]gwapiv1alpha2.ReferenceGrant, len(la.Items))
			for i := range la.Items {
				if err := scheme.Convert(&la.Items[i], &lb.Items[i], scope); err != nil {
					return err
				}
			}
			setApiVersion(b, gwapiv1alpha2.GroupVersion)
			return nil
		})
}

func registerGatewayApiConvertersV1alpha2ToV1(scheme *runtime.Scheme) {
	_ = scheme.Converter().RegisterUntypedConversionFunc(&gwapiv1alpha2.GatewayClassList{}, &gwapiv1.GatewayClassList{},
		func(a, b interface{}, scope conversion.Scope) error {
			lb := b.(*gwapiv1.GatewayClassList)
			la := a.(*gwapiv1alpha2.GatewayClassList)
			lb.Items = make([]gwapiv1.GatewayClass, len(la.Items))
			for i := range la.Items {
				if err := scheme.Convert(&la.Items[i], &lb.Items[i], scope); err != nil {
					return err
				}
			}
			setApiVersion(b, gwapiv1.GroupVersion)
			return nil
		})
	_ = scheme.Converter().RegisterUntypedConversionFunc(&gwapiv1alpha2.GatewayClass{}, &gwapiv1.GatewayClass{},
		func(a, b interface{}, scope conversion.Scope) error {
			*(b.(*gwapiv1.GatewayClass)) = gwapiv1.GatewayClass(*a.(*gwapiv1alpha2.GatewayClass))
			setApiVersion(b, gwapiv1.GroupVersion)
			return nil
		})
	_ = scheme.Converter().RegisterUntypedConversionFunc(&gwapiv1alpha2.GatewayList{}, &gwapiv1.GatewayList{},
		func(a, b interface{}, scope conversion.Scope) error {
			lb := b.(*gwapiv1.GatewayList)
			la := a.(*gwapiv1alpha2.GatewayList)
			lb.Items = make([]gwapiv1.Gateway, len(la.Items))
			for i := range la.Items {
				if err := scheme.Convert(&la.Items[i], &lb.Items[i], scope); err != nil {
					return err
				}
			}
			setApiVersion(b, gwapiv1.GroupVersion)
			return nil
		})
	_ = scheme.Converter().RegisterUntypedConversionFunc(&gwapiv1alpha2.Gateway{}, &gwapiv1.Gateway{},
		func(a, b interface{}, scope conversion.Scope) error {
			*(b.(*gwapiv1.Gateway)) = gwapiv1.Gateway(*a.(*gwapiv1alpha2.Gateway))
			setApiVersion(b, gwapiv1.GroupVersion)
			return nil
		})
	_ = scheme.Converter().RegisterUntypedConversionFunc(&gwapiv1alpha2.HTTPRouteList{}, &gwapiv1.HTTPRouteList{},
		func(a, b interface{}, scope conversion.Scope) error {
			lb := b.(*gwapiv1.HTTPRouteList)
			la := a.(*gwapiv1alpha2.HTTPRouteList)
			lb.Items = make([]gwapiv1.HTTPRoute, len(la.Items))
			for i := range la.Items {
				if err := scheme.Convert(&la.Items[i], &lb.Items[i], scope); err != nil {
					return err
				}
			}
			setApiVersion(b, gwapiv1.GroupVersion)
			return nil
		})
	_ = scheme.Converter().RegisterUntypedConversionFunc(&gwapiv1alpha2.HTTPRoute{}, &gwapiv1.HTTPRoute{},
		func(a, b interface{}, scope conversion.Scope) error {
			*(b.(*gwapiv1.HTTPRoute)) = gwapiv1.HTTPRoute(*a.(*gwapiv1alpha2.HTTPRoute))
			setApiVersion(b, gwapiv1.GroupVersion)
			return nil
		})
}

func registerGatewayApiConvertersV1alpha2ToV1beta1(scheme *runtime.Scheme) {
	_ = scheme.Converter().RegisterUntypedConversionFunc(&gwapiv1alpha2.GatewayClassList{}, &gwapiv1beta1.GatewayClassList{},
		func(a, b interface{}, scope conversion.Scope) error {
			lb := b.(*gwapiv1beta1.GatewayClassList)
			la := a.(*gwapiv1alpha2.GatewayClassList)
			lb.Items = make([]gwapiv1beta1.GatewayClass, len(la.Items))
			for i := range la.Items {
				if err := scheme.Convert(&la.Items[i], &lb.Items[i], scope); err != nil {
					return err
				}
			}
			setApiVersion(b, gwapiv1beta1.GroupVersion)
			return nil
		})
	_ = scheme.Converter().RegisterUntypedConversionFunc(&gwapiv1alpha2.GatewayClass{}, &gwapiv1beta1.GatewayClass{},
		func(a, b interface{}, scope conversion.Scope) error {
			*(b.(*gwapiv1beta1.GatewayClass)) = gwapiv1beta1.GatewayClass(*a.(*gwapiv1alpha2.GatewayClass))
			setApiVersion(b, gwapiv1beta1.GroupVersion)
			return nil
		})
	_ = scheme.Converter().RegisterUntypedConversionFunc(&gwapiv1alpha2.GatewayList{}, &gwapiv1beta1.GatewayList{},
		func(a, b interface{}, scope conversion.Scope) error {
			lb := b.(*gwapiv1beta1.GatewayList)
			la := a.(*gwapiv1alpha2.GatewayList)
			lb.Items = make([]gwapiv1beta1.Gateway, len(la.Items))
			for i := range la.Items {
				if err := scheme.Convert(&la.Items[i], &lb.Items[i], scope); err != nil {
					return err
				}
			}
			setApiVersion(b, gwapiv1beta1.GroupVersion)
			return nil
		})
	_ = scheme.Converter().RegisterUntypedConversionFunc(&gwapiv1alpha2.Gateway{}, &gwapiv1beta1.Gateway{},
		func(a, b interface{}, scope conversion.Scope) error {
			*(b.(*gwapiv1beta1.Gateway)) = gwapiv1beta1.Gateway(*a.(*gwapiv1alpha2.Gateway))
			setApiVersion(b, gwapiv1beta1.GroupVersion)
			return nil
		})
	_ = scheme.Converter().RegisterUntypedConversionFunc(&gwapiv1alpha2.HTTPRouteList{}, &gwapiv1beta1.HTTPRouteList{},
		func(a, b interface{}, scope conversion.Scope) error {
			lb := b.(*gwapiv1beta1.HTTPRouteList)
			la := a.(*gwapiv1alpha2.HTTPRouteList)
			lb.Items = make([]gwapiv1beta1.HTTPRoute, len(la.Items))
			for i := range la.Items {
				if err := scheme.Convert(&la.Items[i], &lb.Items[i], scope); err != nil {
					return err
				}
			}
			setApiVersion(b, gwapiv1beta1.GroupVersion)
			return nil
		})
	_ = scheme.Converter().RegisterUntypedConversionFunc(&gwapiv1alpha2.HTTPRoute{}, &gwapiv1beta1.HTTPRoute{},
		func(a, b interface{}, scope conversion.Scope) error {
			*(b.(*gwapiv1beta1.HTTPRoute)) = gwapiv1beta1.HTTPRoute(*a.(*gwapiv1alpha2.HTTPRoute))
			setApiVersion(b, gwapiv1beta1.GroupVersion)
			return nil
		})
	_ = scheme.Converter().RegisterUntypedConversionFunc(&gwapiv1alpha2.ReferenceGrantList{}, &gwapiv1beta1.ReferenceGrantList{},
		func(a, b interface{}, scope conversion.Scope) error {
			lb := b.(*gwapiv1beta1.ReferenceGrantList)
			la := a.(*gwapiv1alpha2.ReferenceGrantList)
			lb.Items = make([]gwapiv1beta1.ReferenceGrant, len(la.Items))
			for i := range la.Items {
				if err := scheme.Convert(&la.Items[i], &lb.Items[i], scope); err != nil {
					return err
				}
			}
			setApiVersion(b, gwapiv1beta1.GroupVersion)
			return nil
		})
	_ = scheme.Converter().RegisterUntypedConversionFunc(&gwapiv1alpha2.ReferenceGrant{}, &gwapiv1beta1.ReferenceGrant{},
		func(a, b interface{}, scope conversion.Scope) error {
			*(b.(*gwapiv1beta1.ReferenceGrant)) = gwapiv1beta1.ReferenceGrant(*a.(*gwapiv1alpha2.ReferenceGrant))
			setApiVersion(b, gwapiv1beta1.GroupVersion)
			return nil
		})
}
