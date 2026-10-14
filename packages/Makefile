PACKAGES := $(sort $(wildcard *.package))
TARGETS  := $(PACKAGES:.package=)

all: $(TARGETS)

%: %.package
	@./download.sh $< $@
