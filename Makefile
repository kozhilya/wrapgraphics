TEX       := lualatex --shell-escape
TEX_NOSHELL := lualatex
EXDIR     := example

EXAMPLE_TEX := $(wildcard $(EXDIR)/[!_]*.tex)
EXAMPLE_PDFS := $(patsubst %.tex,%.pdf,$(EXAMPLE_TEX))
DOC_PDF   := wrapgraphics-doc.pdf
SOURCES_TEX := wrapgraphics-sources.tex

PYTHON    := python3
DOC_EXTRACT := scripts/doc-extract.py

.PHONY: all clean examples doc doc-extract

all: clean examples doc

examples: $(EXAMPLE_PDFS)

doc-extract: $(SOURCES_TEX)

$(SOURCES_TEX): wrapgraphics.sty wrapgraphics.lua wrapgraphics.py $(DOC_EXTRACT)
	$(PYTHON) $(DOC_EXTRACT) \
	  wrapgraphics.sty latex \
	  wrapgraphics.lua lua \
	  wrapgraphics.py python \
	  -o $@

doc: $(SOURCES_TEX) $(DOC_PDF)

$(EXDIR)/%.pdf: $(EXDIR)/%.tex
	cd $(EXDIR) && $(TEX) $*.tex

$(DOC_PDF): wrapgraphics-doc.tex $(SOURCES_TEX) $(EXAMPLE_PDFS)
	$(TEX) wrapgraphics-doc.tex
	$(TEX) wrapgraphics-doc.tex

clean:
	rm -f $(EXDIR)/*.log $(EXDIR)/*.aux $(EXDIR)/*.fls $(EXDIR)/*.fdb_latexmk $(EXDIR)/*.out
	rm -f wrapgraphics-doc.aux wrapgraphics-doc.log wrapgraphics-doc.out $(SOURCES_TEX)
