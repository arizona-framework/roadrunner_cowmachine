# roadrunner_cowmachine Makefile — thin wrapper over the common rebar3 targets.

SHELL := /bin/bash

.PHONY: all help compile test precommit doc fmt fmt-check \
	xref hank dialyzer eunit ct cover lint \
	clean clean-doc clean-build distclean

all: precommit

help:
	@echo "roadrunner_cowmachine — common make targets"
	@echo ""
	@echo "  compile       rebar3 compile"
	@echo "  test          rebar3 precommit (fmt-check, xref, hank, dialyzer, eunit, ct, 100% cover)"
	@echo "  precommit     alias for 'test'"
	@echo "  doc           rebar3 ex_doc (writes ./doc/)"
	@echo "  fmt           rebar3 fmt (writes)"
	@echo "  fmt-check     rebar3 fmt --check (CI / pre-push)"
	@echo "  lint          fmt-check + xref + hank + doc (CI Lint job)"
	@echo "  xref / hank / dialyzer / eunit / ct / cover  individual rebar3 stages"
	@echo ""
	@echo "  clean         rebar3 clean"
	@echo "  clean-doc     rm -rf ./doc"
	@echo "  clean-build   rm -rf ./_build"
	@echo "  distclean     clean-build + clean-doc + remove erl_crash.dump etc"

compile:
	rebar3 compile

test precommit:
	rebar3 precommit

doc:
	rebar3 ex_doc

fmt:
	rebar3 fmt

fmt-check:
	rebar3 fmt --check

xref:
	rebar3 xref

hank:
	rebar3 hank

dialyzer:
	rebar3 dialyzer

eunit:
	rebar3 eunit --cover

ct:
	rebar3 ct --cover

cover:
	rebar3 cover --verbose --min_coverage=100

# The fast static checks, grouped for the split CI `Lint` job (erlang.yml).
# `make precommit` stays the single local pre-push gate; CI runs `lint`,
# `dialyzer`, and the eunit/ct/cover trio as separate parallel jobs.
lint: fmt-check xref hank doc

clean:
	rebar3 clean

clean-doc:
	rm -rf ./doc

clean-build:
	rm -rf ./_build

distclean: clean-build clean-doc
	rm -f erl_crash.dump rebar3.crashdump
