import Bridge

func bump(_ counter: Counter) {
	counter.increment(by: 2)
}

bump(Counter())
