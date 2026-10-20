// Manual-activation tabs keep layout selection predictable with keyboard and touch.
const layoutTabs = [...document.querySelectorAll('.layout-switcher [role="tab"]')];
function selectLayout(tab) {
  for (const candidate of layoutTabs) {
    const selected = candidate === tab;
    candidate.setAttribute('aria-selected', String(selected));
    candidate.tabIndex = selected ? 0 : -1;
    document.getElementById(candidate.getAttribute('aria-controls')).hidden = !selected;
  }
}
for (const tab of layoutTabs) {
  tab.addEventListener('click', () => selectLayout(tab));
  tab.addEventListener('keydown', (event) => {
    let index = layoutTabs.indexOf(tab);
    if (event.key === 'ArrowRight') index = (index + 1) % layoutTabs.length;
    else if (event.key === 'ArrowLeft') index = (index - 1 + layoutTabs.length) % layoutTabs.length;
    else if (event.key === 'Home') index = 0;
    else if (event.key === 'End') index = layoutTabs.length - 1;
    else return;
    event.preventDefault();
    layoutTabs[index].focus();
  });
}
