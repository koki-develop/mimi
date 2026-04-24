CLT_FRAMEWORKS = /Library/Developer/CommandLineTools/Library/Developer/Frameworks
CLT_TESTING_LIB = /Library/Developer/CommandLineTools/Library/Developer/usr/lib

.PHONY: build test run clean fmt lint

build:
	swift build

# Works both with full Xcode (swift test "just works") and with
# Command Line Tools only (needs explicit framework search paths
# and rpaths so Testing.framework / lib_TestingInterop.dylib can
# be found at runtime).
test:
	@if [ -d "$(CLT_FRAMEWORKS)" ] && [ ! -d "/Applications/Xcode.app" ]; then \
		swift test \
			-Xswiftc -F -Xswiftc "$(CLT_FRAMEWORKS)" \
			-Xlinker -F -Xlinker "$(CLT_FRAMEWORKS)" \
			-Xlinker -rpath -Xlinker "$(CLT_FRAMEWORKS)" \
			-Xlinker -rpath -Xlinker "$(CLT_TESTING_LIB)"; \
	else \
		swift test; \
	fi

run:
	swift run transcribe $(ARGS)

clean:
	swift package clean

fmt:
	swift format format --in-place --recursive Sources Tests

lint:
	swift format lint --strict --recursive Sources Tests
