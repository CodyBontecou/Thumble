// Qt supplies this script from its own trusted resources. WebKit does not need it.
if (window.qt?.webChannelTransport) {
  const script = document.createElement('script');
  script.src = 'qrc:///qtwebchannel/qwebchannel.js';
  document.head.append(script);
}
