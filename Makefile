TEX       := lualatex --shell-escape
TEX_NOSHELL := lualatex
EXDIR     := example

EXAMPLE_TEX := $(wildcard $(EXDIR)/*.tex)
EXAMPLE_PDFS := $(patsubst %.tex,%.pdf,$(EXAMPLE_TEX))
DOC_PDF   := wrapgraphics-doc.pdf

.PHONY: all clean

all: $(EXAMPLE_PDFS) $(DOC_PDF)

$(EXDIR)/%.pdf: $(EXDIR)/%.tex
	cd $(EXDIR) && $(TEX) $*.tex && \
	  rm -f $*.aux $*.log $*.fls $*.fdb_latexmk

$(DOC_PDF): wrapgraphics-doc.tex $(EXAMPLE_PDFS)
	$(TEX_NOSHELL) wrapgraphics-doc.tex && \
	  $(TEX_NOSHELL) wrapgraphics-doc.tex && \
	  rm -f wrapgraphics-doc.aux wrapgraphics-doc.log wrapgraphics-doc.out

clean:
	rm -f $(EXDIR)/*.log $(EXDIR)/*.aux $(EXDIR)/*.fls $(EXDIR)/*.fdb_latexmk $(EXDIR)/*.out
	rm -f wrapgraphics-doc.aux wrapgraphics-doc.log wrapgraphics-doc.out
