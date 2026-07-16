all:
	@set -eu; \
	for file in judger busybox zstd; do \
		tmp=".$$file.hull-prepare-$$$$"; \
		cp "$$file" "$$tmp"; \
		chmod 0755 "$$tmp"; \
		mv -f "$$tmp" "$$file"; \
	done
