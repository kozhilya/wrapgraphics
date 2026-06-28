TEX       := lualatex --shell-escape --output-directory=build
SRCDIR    := ..
EXAMPLES  := $(wildcard $(SRCDIR)/example/*.tex)
PDFS      := $(patsubst $(SRCDIR)/example/%.tex,%.pdf,$(EXAMPLES))

.PHONY: all clean

all: $(PDFS)

%.pdf: $(SRCDIR)/example/%.tex
	$(TEX) $(SRCDIR)/example/$*.tex

clean:
	rm -f *.pdf *.log *.aux *.fls *.fdb_latexmk
