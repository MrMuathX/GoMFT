// Keep `body.dark` in sync with `html.dark`.
// Theme colours themselves come from CSS custom properties on <html>; the
// settings sub-menu toggle and the active-nav marker live in layout.templ.
document.addEventListener('DOMContentLoaded', function() {
    if (document.documentElement.classList.contains('dark')) {
        document.body.classList.add('dark');
    }
});
