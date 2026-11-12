package webhooks_test

import (
	"fmt"

	"example.com/webhooks"
)

func Example() {
	key, _ := webhooks.ParseSecret("whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw")
	body := []byte(`{"test": 2432232314}`)

	header := webhooks.SignHeader([][]byte{key}, "msg_p5jXN8AQM9LWM0D4loKWxJek", "1614265330", body)
	fmt.Println(header)

	m, err := webhooks.Verify([][]byte{key}, "msg_p5jXN8AQM9LWM0D4loKWxJek", "1614265330", header, body, 1614265400)
	fmt.Println(m, err)

	_, err = webhooks.Verify([][]byte{key}, "msg_p5jXN8AQM9LWM0D4loKWxJek", "1614265330", header, body, 1614265631)
	fmt.Println(err)
	// Output:
	// v1,g0hM9SsE+OTPJTGt/tmIKtSyZlE3uFJELVlNIOLJ1OE=
	// {0 0} <nil>
	// timestamp-too-old
}
