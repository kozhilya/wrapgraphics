TEX       := lualatex --shell-escape
SRCDIR    := ..
EXAMPLES  := $(wildcard $(SRCDIR)/example/*.tex)
PDFS      := $(patsubst $(SRCDIR)/example/%.tex,%.pdf,$(EXAMPLES))

.PHONY: all clean

all: $(PDFS)

%.pdf: $(SRCDIR)/example/%.tex
	cd $(SRCDIR) && $(TEX) --output-directory=$(CURDIR) example/$*.tex

clean:
	rm -f *.pdf *.log *.aux *.fls *.fdb_latexmk
