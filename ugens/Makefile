# Builds BeadsUGen.so - run this ON the norns device (native arm build).
#   make            - build BeadsUGen.so
#   make install    - install into ~/.local/share/SuperCollider/Extensions/BeadsUGens
#   make clean
#
# Requires: g++ (and make). No cmake needed.
# The vendored headers in sc-plugin-headers/ were taken from SuperCollider
# 3.13.0; the plugin API is stable across 3.11-3.13, so these work with the
# scsynth shipped by norns.

CXX      ?= g++
CXXFLAGS := -shared -fPIC -O2 -std=gnu++14 -DTEST -Wno-unknown-pragmas \
            -Isc-plugin-headers -Ieurorack-beads

SRCS := beads_ugen.cpp \
	eurorack-beads/beads/dsp/processor.cc \
	eurorack-beads/beads/dsp/trigger_generator.cc \
	eurorack-beads/beads/dsp/delay_controller.cc \
	eurorack-beads/beads/dsp/delay_clock.cc \
	eurorack-beads/beads/dsp/mu_law.cc \
	eurorack-beads/beads/resources.cc \
	eurorack-beads/stmlib/utils/random.cc

OBJS := $(SRCS:.cc=.o)
OBJS := $(OBJS:.cpp=.o)

BeadsUGen.so: $(OBJS)
	$(CXX) -shared -o $@ $(OBJS)

%.o: %.cpp
	$(CXX) $(CXXFLAGS) -c $< -o $@

%.o: %.cc
	$(CXX) $(CXXFLAGS) -c $< -o $@

install: BeadsUGen.so
	mkdir -p ~/.local/share/SuperCollider/Extensions/BeadsUGens
	cp BeadsUGen.so ~/.local/share/SuperCollider/Extensions/BeadsUGens/
	# the .sc may be absent from this build tree (removed to avoid duplicate
	# class compilation, since sclang compiles everything under ~/dust);
	# it only needs installing once - Extensions keeps it across updates
	-cp BeadsUGen.sc ~/.local/share/SuperCollider/Extensions/BeadsUGens/

clean:
	rm -f $(OBJS) BeadsUGen.so

.PHONY: install clean
