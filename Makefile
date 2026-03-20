.PHONY: generate open build

generate:
	xcodegen generate

open: generate
	open SolWhisper.xcodeproj

build: generate
	xcodebuild -project SolWhisper.xcodeproj -scheme SolWhisper -configuration Debug build

install-xcodegen:
	brew install xcodegen
