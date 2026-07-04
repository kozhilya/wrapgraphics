# PLANS.md — wrapgraphics

## 🔧 Приоритетные

- **Перепроверить `twocolumn-middle`** — не тестировался после фикса `wr_deferred.lines_since_start`. Убедиться, что второй столбец отрабатывает корректно.
- **Пример с произвольными вертикальными аномалиями** — `\AddToHook{para/begin}` спасает от `\@afterheading` (`\subsection*`, `\item`), но другие LaTeX-конструкции могут сбрасывать `\everypar` или ломать parshape. Нужен демо-пример, а не только точечные обработки в `obstacle-*.tex`.
- **Починить `anchor`** — Section 8 «Broken examples». Три примера (`anchor.tex`, `anchor-se.tex`, `anchor-shift.tex`) не работают. Код в `wr_build_image_box()` есть, но горизонтальное позиционирование не совпадает с parshape, а `\pagetotal` для вертикального позиционирования ненадёжен в контексте параграфа.
- **Документировать `smooth`** — ключ `smooth` (sigma для Gaussian blur) полностью реализован, но нет примера, нет упоминания в документации.
- **Сниппеты не соответствуют примерам**:
  - `_code-twocolumn-wide.tex` — отсутствует `position=twocolumn-wide`
  - `_code-twocolumn-middle.tex` — использует `position=middle` вместо `position=twocolumn-middle`, и другой `width`
- **Документировать `position` значения** — Section 5.2 перечисляет только `left`, `right`, `middle`. Нужно добавить `twocolumn-wide`, `twocolumn-middle` и указать, что `middle` требует `twocolumn`.

## 📘 Документация

- Секция 5.2 — перечислить все 5 значений `position` с указанием режима работы (single-column / two-column)
- Документировать `smooth` (секция 5.x)
- Решить судьбу `position=middle` в одноколоночном режиме: в `wr_indent_for_line_middle()` и `wr_build_parshape()` код есть, но стоит guard с `\PackageError`. Либо убрать guard и протестировать, либо убрать из документации.

## 🧪 Тесты

- **Создать `tests/`** — сейчас нет ни одного теста. `python -m pytest tests/` падает сразу. Покрыть:
  - Python: `load_alpha()`, `threshold()`, `dilate_fast()`, `trace_contour()`, `_find_start()`, `_simplify(RDP)`, `smooth_contour()`, `write_svg()`
  - Lua: `wr_parse_svg()` (валидные/невалидные SVG, пустой контур), `wr_compute_scale()`, `wr_contour_bounds()`, `wr_indent_for_line()` (все position), `wr_build_parshape()`, `wr_build_parshape_col()`, `clear_on_page_change()`, deferred cutout
  - Интеграционные: Lua → Python → SVG → parshape
  - Регрессионные: каждый починенный баг

## 🔩 Код / Архитектура

- **Expose Python CLI флаги как LaTeX-ключи**:
  - `simplify` (bool) — соответствует `--simplify`/`--no-simplify`
  - `epsilon` (float, default `3.0`) — RDP tolerance
  - `invert` (bool) — `--invert`. Lua уже читает `wg-invert` из SVG (строка 473), но нет ключа в `.sty`
- **Убрать `\everypar`** — сейчас перезаписывается глобально (строка 1370). `\AddToHook{para/begin}` уже добавлен, можно удалить `\everypar`.
- **Отключить `post_linebreak_filter`** когда больше нет изображений — сейчас висит на весь документ
- **Улучшить сообщения об ошибках**:
  - Если Python/Pillow не установлены — человекочитаемое сообщение вместо кода возврата shell
  - Если изображение не имеет alpha-канала — падает молча
  - Если SVG от Python кривой — нечитаемая ошибка от string matching
- **`position=middle` в одноколоночном**: убрать guard (строка 1203) или явно удалить из документации

## ✨ Новые фичи

- **`debug` / `showbounds`** — опция для рендеринга bounding box контура и parshape, удобно для отладки
- **Multi-image-per-paragraph** — поддержка нескольких `\wrapgraphics` в одном параграфе
- **CI (GitHub Actions)** — `pytest` + компиляция всех примеров при каждом push
- **Валидация alpha-канала** — проверять наличие alpha в изображении и выдавать понятную ошибку
- **`columnsep` как ключ** — сейчас читается глобальный `\the\columnsep`, нельзя переопределить для конкретного `\wrapgraphics`
- **Ленивая загрузка Lua-модуля** — `dofile("wrapgraphics.lua")` вызывается при загрузке пакета, даже если `\wrapgraphics` не используется
