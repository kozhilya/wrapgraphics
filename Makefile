TEX       := lualatex --shell-escape
TEX_NOSHELL := lualatex
EXDIR     := example

EXAMPLE_TEX := $(wildcard $(EXDIR)/*.tex)
EXAMPLE_PDFS := $(patsubst %.tex,%.pdf,$(EXAMPLE_TEX))
DOC_PDF   := wrapgraphics-doc.pdf

.PHONY: all clean examples doc

all: clean examples doc

examples: $(EXAMPLE_PDFS)

doc: $(DOC_PDF)

$(EXDIR)/%.pdf: $(EXDIR)/%.tex
	cd $(EXDIR) && $(TEX) $*.tex

$(DOC_PDF): wrapgraphics-doc.tex $(EXAMPLE_PDFS)
	$(TEX) wrapgraphics-doc.tex
	$(TEX) wrapgraphics-doc.tex

clean:
	rm -f $(EXDIR)/*.log $(EXDIR)/*.aux $(EXDIR)/*.fls $(EXDIR)/*.fdb_latexmk $(EXDIR)/*.out
	rm -f wrapgraphics-doc.aux wrapgraphics-doc.log wrapgraphics-doc.out
