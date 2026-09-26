.PHONY: dev down status logs check test dev-reset

dev down status logs dev-reset:
	@./scripts/dev.sh "$@" $(ARGS)

check:
	@./scripts/check.sh $(ARGS)

test:
	@./scripts/test.sh $(ARGS)
