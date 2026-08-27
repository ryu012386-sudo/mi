NAME    := resetuuid
SDK     := $(shell xcrun --sdk iphoneos --show-sdk-path)
CC      := $(shell xcrun --sdk iphoneos -f clang)
ARCHS   := -arch arm64
MINVER  := -miphoneos-version-min=13.0
FRAMEWORKS := -framework Foundation -framework Security -framework UIKit -framework PhotosUI -framework UniformTypeIdentifiers

$(NAME).dylib: $(NAME).m
	$(CC) $(ARCHS) -isysroot "$(SDK)" $(MINVER) -fobjc-arc \
	  -dynamiclib \
	  -install_name @executable_path/$(NAME).dylib \
	  $(FRAMEWORKS) \
	  -o $@ $<
	codesign -f -s - $@
	@echo "built: $@"

clean:
	rm -f $(NAME).dylib
