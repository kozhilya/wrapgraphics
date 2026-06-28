TEX       := lualatex --shell-escape
EXDIR     := example

EXAMPLE_TEX := $(filter-out $(EXDIR)/wrapgraphics-doc.tex, $(wildcard $(EXDIR)/*.tex))
EXAMPLE_PDFS := $(patsubst %.tex,%.pdf,$(EXAMPLE_TEX))
DOC_PDF   := $(EXDIR)/wrapgraphics-doc.pdf

.PHONY: all clean

all: $(EXAMPLE_PDFS) $(DOC_PDF)

$(EXDIR)/%.pdf: $(EXDIR)/%.tex
	cd $(EXDIR) && $(TEX) $*.tex && \
	  rm -f $*.aux $*.log $*.fls $*.fdb_latexmk

$(DOC_PDF): $(EXDIR)/wrapgraphics-doc.tex $(EXAMPLE_PDFS)
	cd $(EXDIR) && $(TEX) wrapgraphics-doc.tex && \
	  $(TEX) wrapgraphics-doc.tex && \
	  rm -f wrapgraphics-doc.aux wrapgraphics-doc.log wrapgraphics-doc.out

clean:
	rm -f $(EXDIR)/*.log $(EXDIR)/*.aux $(EXDIR)/*.fls $(EXDIR)/*.fdb_latexmk $(EXDIR)/*.out
