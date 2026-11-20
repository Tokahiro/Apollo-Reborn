# Used by scripts/check-compile-linux.sh: compiles the tweak's sources for
# iOS, rebuilding only what changed (clang -MMD dependency files).
#
# Inputs: REPO, OUT, SOURCES (repo-relative), LOGOS (path to logos.pl),
# FLAGS_FILE and LOGOS_FLAGS_FILE (one flag per line), STAMP_FILE (compiler and
# pinned commits). These files and the check's own scripts are prerequisites of
# every object, so a change to any of them rebuilds everything.

FLAGS := $(shell cat $(FLAGS_FILE))
LOGOS_FLAGS := $(shell cat $(LOGOS_FLAGS_FILE))
OBJECTS := $(patsubst %,$(OUT)/%.o,$(SOURCES))
INPUTS := $(FLAGS_FILE) $(LOGOS_FLAGS_FILE) $(STAMP_FILE) $(lastword $(MAKEFILE_LIST)) $(REPO)/scripts/check-compile-linux.sh

all: $(OBJECTS)

# Logos output goes to OUT, never next to the source. On failure the old
# object is removed too, so the linkage check can't read a stale one.
$(OUT)/%.xm.mm: $(REPO)/%.xm $(INPUTS)
	@mkdir -p $(@D)
	@perl $(LOGOS) $(LOGOS_FLAGS) $< > $@.tmp 2> $@.log && mv $@.tmp $@ \
		|| { echo "FAILED  $*.xm (Logos)"; sed 's/^/        /' $@.log; rm -f $@.tmp $(@:.mm=.o); exit 1; }

# compile <compiler>,<language>,<input>,<name>,<extra flags>
define compile
	@mkdir -p $(@D)
	@$(1) -x $(2) $(FLAGS) $(5) -MMD -MP -MF $@.d -c $(3) -o $@ 2> $@.log \
		|| { echo "FAILED  $(4)"; grep -E '(error|warning):' $@.log | sed 's/^/        /' | head -20; rm -f $@; exit 1; }
endef

# Theos adds the source's own directory to the include path for Logos files only.
$(OUT)/%.xm.o: $(OUT)/%.xm.mm $(INPUTS)
	$(call compile,clang++,objective-c++,$<,$*.xm,-I$(dir $(REPO)/$*))

$(OUT)/%.mm.o: $(REPO)/%.mm $(INPUTS)
	$(call compile,clang++,objective-c++,$<,$*.mm)

$(OUT)/%.m.o: $(REPO)/%.m $(INPUTS)
	$(call compile,clang,objective-c,$<,$*.m)

$(OUT)/%.cpp.o: $(REPO)/%.cpp $(INPUTS)
	$(call compile,clang++,c++,$<,$*.cpp)

$(OUT)/%.c.o: $(REPO)/%.c $(INPUTS)
	$(call compile,clang,c,$<,$*.c)

.SECONDARY:

-include $(OBJECTS:%=%.d)
