CC = clang
ARCHS = -arch arm64 -arch x86_64
MIN_VERSION = -mmacosx-version-min=14.0
FRAMEWORKS = -framework Foundation -framework AppKit -framework AVFoundation -framework CoreServices
OBJC_FLAGS = -fobjc-arc -fmodules
LINKER_FLAGS = -undefined dynamic_lookup -dynamiclib

PRODUCT_NAME = MotionKit
FRAMEWORK_BUNDLE_ID = com.motionkit.MotionKit
MODDED_APP_BUNDLE_ID = com.motionkit.motionapp
HOST_APP_NAME = Motion
HOST_EXECUTABLE = Motion
MOTIONKIT_PORT ?= 9878
SOURCE_APP = /Applications/Motion.app
MODDED_APP_ROOT = $(HOME)/Applications/$(PRODUCT_NAME)
MODDED_APP = $(MODDED_APP_ROOT)/$(HOST_APP_NAME).app
FW_DIR = $(MODDED_APP)/Contents/Frameworks/$(PRODUCT_NAME).framework
INSTALL_NAME = -install_name @rpath/$(PRODUCT_NAME).framework/Versions/A/$(PRODUCT_NAME)
TOOLS_DIR = $(MODDED_APP_ROOT)/tools
APP_SUPPORT_DIR = $(HOME)/Library/Application\ Support/$(PRODUCT_NAME)/lua

SOURCES = Sources/SpliceKit.m \
          Sources/SpliceKitRuntime.m \
          Sources/SpliceKitSwizzle.m \
          Sources/SpliceKitServer.m \
          Sources/SpliceKitLogPanel.m \
          Sources/SpliceKitTranscriptPanel.m \
          Sources/SpliceKitCaptionPanel.m \
          Sources/SpliceKitCommandPalette.m \
          Sources/SpliceKitDebugUI.m \
          Sources/SpliceKitLua.m \
          Sources/SpliceKitLuaPanel.m

BUILD_DIR = build
OUTPUT = $(BUILD_DIR)/$(PRODUCT_NAME)
ENTITLEMENTS = entitlements.plist

LUA_DIR = vendor/lua-5.4.7/src
LUA_SRCS = $(filter-out $(LUA_DIR)/lua.c $(LUA_DIR)/luac.c, $(wildcard $(LUA_DIR)/*.c))
LUA_OBJS = $(patsubst $(LUA_DIR)/%.c, $(BUILD_DIR)/lua/%.o, $(LUA_SRCS))
LUA_LIB = $(BUILD_DIR)/liblua.a

SILENCE_DETECTOR = $(BUILD_DIR)/silence-detector

.PHONY: all clean copy-app deploy launch launch-foreground tools smoke-motion

all: $(OUTPUT)

tools: $(SILENCE_DETECTOR)

$(SILENCE_DETECTOR): tools/silence-detector.swift
	@mkdir -p $(BUILD_DIR)
	swiftc -O -suppress-warnings -o $(SILENCE_DETECTOR) tools/silence-detector.swift
	@echo "Built: $(SILENCE_DETECTOR)"

$(BUILD_DIR)/lua/%.o: $(LUA_DIR)/%.c
	@mkdir -p $(BUILD_DIR)/lua
	$(CC) $(ARCHS) $(MIN_VERSION) -DLUA_USE_MACOSX -O2 -Wall -c $< -o $@

$(LUA_LIB): $(LUA_OBJS)
	libtool -static -o $@ $^
	@echo "Built: $(LUA_LIB)"

$(OUTPUT): $(SOURCES) Sources/SpliceKit.h $(LUA_LIB)
	@mkdir -p $(BUILD_DIR)
	$(CC) $(ARCHS) $(MIN_VERSION) $(FRAMEWORKS) $(OBJC_FLAGS) $(LINKER_FLAGS) \
		$(INSTALL_NAME) -I Sources -I $(LUA_DIR) \
		$(SOURCES) $(LUA_LIB) -o $(OUTPUT)
	@echo "Built: $(OUTPUT)"
	@file $(OUTPUT)

clean:
	rm -rf $(BUILD_DIR)

copy-app:
	@echo "=== Copying Motion.app to $(MODDED_APP) ==="
	@test -d "$(SOURCE_APP)" || (echo "Source app not found: $(SOURCE_APP)" && exit 1)
	@mkdir -p "$(MODDED_APP_ROOT)"
	rsync -a --delete "$(SOURCE_APP)/" "$(MODDED_APP)/"
	@xattr -cr "$(MODDED_APP)"
	@echo "=== Motion copy ready ==="

deploy: $(OUTPUT) $(SILENCE_DETECTOR)
	@echo "=== Deploying $(PRODUCT_NAME) to modded Motion ==="
	@test -d "$(MODDED_APP)" || (echo "Modded app not found. Run 'make copy-app' first." && exit 1)
	@mkdir -p "$(FW_DIR)/Versions/A/Resources"
	cp $(OUTPUT) "$(FW_DIR)/Versions/A/$(PRODUCT_NAME)"
	@cd "$(FW_DIR)/Versions" && ln -sf A Current
	@cd "$(FW_DIR)" && ln -sf Versions/Current/$(PRODUCT_NAME) $(PRODUCT_NAME)
	@cd "$(FW_DIR)" && ln -sf Versions/Current/Resources Resources
	@test -f "$(FW_DIR)/Versions/A/Resources/Info.plist" || \
		printf '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>$(FRAMEWORK_BUNDLE_ID)</string><key>CFBundleName</key><string>$(PRODUCT_NAME)</string><key>CFBundleVersion</key><string>0.1.0</string><key>CFBundlePackageType</key><string>FMWK</string><key>CFBundleExecutable</key><string>$(PRODUCT_NAME)</string></dict></plist>' \
		> "$(FW_DIR)/Versions/A/Resources/Info.plist"
	@/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $(MODDED_APP_BUNDLE_ID)" "$(MODDED_APP)/Contents/Info.plist"
	@/usr/libexec/PlistBuddy -c "Set :CFBundleName $(PRODUCT_NAME)" "$(MODDED_APP)/Contents/Info.plist"
	@/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $(PRODUCT_NAME)" "$(MODDED_APP)/Contents/Info.plist"
	@/usr/libexec/PlistBuddy -c "Delete :LSEnvironment" "$(MODDED_APP)/Contents/Info.plist" 2>/dev/null || true
	@/usr/libexec/PlistBuddy -c "Add :LSEnvironment dict" "$(MODDED_APP)/Contents/Info.plist"
	@/usr/libexec/PlistBuddy -c "Add :LSEnvironment:DYLD_INSERT_LIBRARIES string $(FW_DIR)/Versions/A/$(PRODUCT_NAME)" "$(MODDED_APP)/Contents/Info.plist"
	@/usr/libexec/PlistBuddy -c "Add :LSEnvironment:MOTIONKIT_PORT string $(MOTIONKIT_PORT)" "$(MODDED_APP)/Contents/Info.plist"
	@/usr/libexec/PlistBuddy -c "Add :LSEnvironment:MOTIONKIT_AUTOCREATE_DOCUMENT string 0" "$(MODDED_APP)/Contents/Info.plist"
	@/usr/libexec/PlistBuddy -c "Add :NSSpeechRecognitionUsageDescription string '$(PRODUCT_NAME) uses speech recognition for text-driven editing workflows.'" "$(MODDED_APP)/Contents/Info.plist" 2>/dev/null || true
	@mkdir -p "$(TOOLS_DIR)"
	@cp $(SILENCE_DETECTOR) "$(TOOLS_DIR)/silence-detector" 2>/dev/null || true
	@test -f tools/parakeet-transcriber/.build/release/parakeet-transcriber && \
		cp tools/parakeet-transcriber/.build/release/parakeet-transcriber "$(TOOLS_DIR)/parakeet-transcriber" || true
	@mkdir -p "$(HOME)/Library/Application Support/$(PRODUCT_NAME)/lua/examples"
	@mkdir -p "$(HOME)/Library/Application Support/$(PRODUCT_NAME)/lua/auto"
	@mkdir -p "$(HOME)/Library/Application Support/$(PRODUCT_NAME)/lua/lib"
	@mkdir -p "$(HOME)/Library/Application Support/$(PRODUCT_NAME)/lua/menu"
	@cp -n scripts/lua/examples/*.lua "$(HOME)/Library/Application Support/$(PRODUCT_NAME)/lua/examples/" 2>/dev/null || true
	@cp -n scripts/lua/menu/*.lua "$(HOME)/Library/Application Support/$(PRODUCT_NAME)/lua/menu/" 2>/dev/null || true
	@cp -n scripts/lua/lib/*.lua "$(HOME)/Library/Application Support/$(PRODUCT_NAME)/lua/lib/" 2>/dev/null || true
	codesign --force --sign - "$(FW_DIR)"
	codesign --force --sign - --deep --entitlements $(ENTITLEMENTS) "$(MODDED_APP)"
	@codesign --verify --verbose "$(MODDED_APP)" 2>&1
	@echo "=== Deployed successfully ==="

launch: deploy
	@echo "=== Launching modded Motion with $(PRODUCT_NAME) ==="
	@mkdir -p "$(HOME)/Library/Logs/$(PRODUCT_NAME)"
	@pkill -x "$(HOST_EXECUTABLE)" >/dev/null 2>&1 || true
	@sleep 1
	@LOG_PATH="$(HOME)/Library/Logs/$(PRODUCT_NAME)/launch.log"; \
	PID_PATH="$(HOME)/Library/Logs/$(PRODUCT_NAME)/motion.pid"; \
	env PRODUCT_NAME="$(PRODUCT_NAME)" HOST_APP_NAME="$(HOST_APP_NAME)" \
		HOST_EXECUTABLE="$(HOST_EXECUTABLE)" MODDED_APP_ROOT="$(MODDED_APP_ROOT)" \
		MODDED_APP="$(MODDED_APP)" DYLIB="$(FW_DIR)/Versions/A/$(PRODUCT_NAME)" \
		MOTIONKIT_PORT="$(MOTIONKIT_PORT)" \
		./scripts/launch.sh >> "$$LOG_PATH" 2>&1 < /dev/null & \
	launcher_pid=$$!; \
	sleep 2; \
	app_pid=$$(pgrep -xn "$(HOST_EXECUTABLE)" || true); \
	if [ -n "$$app_pid" ]; then echo "$$app_pid" > "$$PID_PATH"; else echo "$$launcher_pid" > "$$PID_PATH"; fi; \
	echo "Motion launched (PID $${app_pid:-$$launcher_pid})."; \
	echo "Log: $$LOG_PATH"; \
	echo "Bridge smoke test: MOTIONKIT_PORT=$(MOTIONKIT_PORT) python3 tools/smoke_motion.py --skip-launch"

launch-foreground: deploy
	@env PRODUCT_NAME="$(PRODUCT_NAME)" HOST_APP_NAME="$(HOST_APP_NAME)" \
		HOST_EXECUTABLE="$(HOST_EXECUTABLE)" MODDED_APP_ROOT="$(MODDED_APP_ROOT)" \
		MODDED_APP="$(MODDED_APP)" DYLIB="$(FW_DIR)/Versions/A/$(PRODUCT_NAME)" \
		MOTIONKIT_PORT="$(MOTIONKIT_PORT)" MOTIONKIT_LAUNCH_MODE="exec" \
		./scripts/launch.sh

smoke-motion:
	@python3 tools/smoke_motion.py
