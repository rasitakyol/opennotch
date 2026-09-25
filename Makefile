APP := build/OpenNotch.app

.PHONY: app run probe test install icon clean

app:
	@./Scripts/build-app.sh release

run: app
	@pkill -x OpenNotch || true
	@open $(APP)

probe:
	@swift run -c release OpenNotch --probe

test:
	@swift test

install: app
	@pkill -x OpenNotch || true
	@rm -rf /Applications/OpenNotch.app
	@cp -R $(APP) /Applications/OpenNotch.app
	@open /Applications/OpenNotch.app
	@echo "✓ /Applications/OpenNotch.app"

icon:
	@swift Scripts/make-icon.swift Resources/AppIcon.icns

clean:
	@rm -rf .build build
