TEX       := lualatex --shell-escape
EXDIR     := example

EXAMPLES  := $(wildcard $(EXDIR)/*.tex)
PDFS      := $(patsubst %.tex,%.pdf,$(EXAMPLES))

.PHONY: all clean

all: $(PDFS)

$(EXDIR)/%.pdf: $(EXDIR)/%.tex
	cd $(EXDIR) && $(TEX) $*.tex && \
	  rm -f $*.aux $*.log $*.fls $*.fdb_latexmk

clean:
	rm -f $(EXDIR)/*.log $(EXDIR)/*.aux $(EXDIR)/*.fls $(EXDIR)/*.fdb_latexmk
