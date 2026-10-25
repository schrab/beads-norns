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
# -include stdio.h: the vendored wavetable_granular_player.h prints under
# TEST without including <cstdio>; the vendor tree stays byte-pristine
CXXFLAGS := -shared -fPIC -O3 -funroll-loops -std=gnu++14 -DTEST \
            -include stdio.h -Wno-unknown-pragmas \
            -Isc-plugin-headers -Ieurorack-beads

SRCS := beads_ugen.cpp \
	eurorack-beads/beads/dsp/processor.cc \
	eurorack-beads/beads/dsp/synth.cc \
	eurorack-beads/beads/dsp/trigger_generator.cc \
	eurorack-beads/beads/dsp/delay_controller.cc \
	eurorack-beads/beads/dsp/delay_clock.cc \
	eurorack-beads/beads/dsp/mu_law.cc \
	eurorack-beads/beads/resources.cc \
	eurorack-beads/stmlib/utils/random.cc \
	eurorack-beads/stmlib/dsp/units.cc

OBJS := $(SRCS:.cc=.o)
OBJS := $(OBJS:.cpp=.o)

BeadsUGen.so: $(OBJS)
	$(CXX) -shared -o $@ $(OBJS)

%.o: %.cpp
	$(CXX) $(CXXFLAGS) -c $< -o $@

%.o: %.cc
	$(CXX) $(CXXFLAGS) -c $< -o $@

install: BeadsUGen.so
	# the UGen BINARY goes into the system plugin dir (sudo) - that is the
	# dir the norns scsynth actually scans; do NOT also keep a copy under
	# ~/dust (duplicate registration)
	sudo cp BeadsUGen.so /usr/local/lib/SuperCollider/plugins/
	# the CLASS file lives in user Extensions; it only needs installing once
	# and may be absent from this build tree (sclang compiles everything
	# under ~/dust, so it must not be synced there)
	mkdir -p ~/.local/share/SuperCollider/Extensions/BeadsUGens
	-cp BeadsUGen.sc ~/.local/share/SuperCollider/Extensions/BeadsUGens/

clean:
	rm -f $(OBJS) BeadsUGen.so

.PHONY: install clean
