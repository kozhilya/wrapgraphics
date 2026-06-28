TEX       := lualatex --shell-escape
SRCDIR    := ..
EXDIR     := $(SRCDIR)/example
EXAMPLES  := $(wildcard $(EXDIR)/*.tex)
PDFS      := $(patsubst %.tex,%.pdf,$(EXAMPLES))

.PHONY: all clean

all: $(PDFS)

$(EXDIR)/%.pdf: $(EXDIR)/%.tex
	cd $(SRCDIR) && $(TEX) --output-directory=example example/$*.tex && \
	  rm -f example/$*.aux example/$*.log example/$*.fls example/$*.fdb_latexmk

clean:
	rm -f $(EXDIR)/*.log $(EXDIR)/*.aux $(EXDIR)/*.fls $(EXDIR)/*.fdb_latexmk
