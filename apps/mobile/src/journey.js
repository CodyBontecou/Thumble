import { WOW_CHECKS } from './onboarding-core.js';

// Reconnects preserve confirmations; changing receiver, activation or game
// requires a fresh check. This is player confirmation, not measured gameplay.
export function testContext(access, layout, wowClient = '') {
  if (!/^[a-f0-9-]{36}$/i.test(access?.receiverId || '') || !layout?.profile?.id || !Number.isSafeInteger(layout.revision) || layout.revision < 1) return '';
  return `${access.receiverId}:${layout.profile.id}:${layout.revision}${wowClient ? `:${wowClient}` : ''}`;
}
export function cloudJourney({ cloud, setup, network, layout, access, pairing, layoutPending, recovering }) {
  const selected = cloud.selected, session = cloud.session, delivery = selected?.delivery;
  const delivered = !!session && !!selected && !!delivery && delivery.deviceId === session.device.id && delivery.profileId === selected.profile.id && delivery.profileRevision === selected.revision && ['received', 'rendered'].includes(delivery.state);
  const proof = cloud.macAdoption;
  const ready = delivered && network.phase === 'connected' && !!proof && proof.pairing === pairing && proof.source.service === session.service && proof.source.accountId === session.accountId && proof.source.profileId === selected.profile.id && proof.source.revision === selected.revision && proof.profileId === layout.profile.id && proof.activationRevision === layout.revision && !layoutPending && !recovering;
  const context = testContext(access, layout, setup.wowClient);
  const tested = ready && !!setup.wowClient && !!context && setup.controlsTested && setup.controlsCheckContext === testContext(access, layout) && setup.wowCheckContext === context && setup.wowTested && setup.consolePortReady && WOW_CHECKS.every(check => setup.wowChecks[check.id] === true);
  const steps = [
    { id: 'agent', title: 'AI connected', done: delivered, detail: delivered ? 'Your AI’s controller reached this signed-in phone.' : session ? 'Phone signed in. Share your request; a delivery confirms the connection.' : 'Sign in on this phone, then connect your AI to the same account.' },
    { id: 'delivery', title: 'Controller delivered', done: delivered, detail: delivered ? `${selected.profile.name} · revision ${selected.revision}${delivery.state === 'rendered' ? ' · rendered on this phone' : ' · downloaded'}` : 'Keep Thumble open while your AI validates and sends the controller.' },
    { id: 'mac', title: 'Computer ready', done: ready, detail: ready ? 'This exact controller is acknowledged on your paired computer.' : network.phase !== 'connected' ? 'Connect your computer, then explicitly use the delivered controller there.' : 'Use this controller on computer. A practice preview does not activate it.' },
    { id: 'wow', title: 'Tested in WoW', done: tested, detail: tested ? 'You confirmed all five checks for this controller and WoW installation.' : 'Prepare ConsolePort, then confirm movement, camera, an action, modifiers and menus.' },
  ];
  const route = !delivered ? '/cloud' : network.phase !== 'connected' ? '/pair?setup=1&returnTo=journey' : !ready ? '/cloud' : !tested ? '/wow-setup' : '/?practice=1';
  const action = !session ? 'Sign in and connect your AI' : !delivered ? 'Request your controller' : network.phase !== 'connected' ? 'Connect computer' : !ready ? 'Use controller on computer' : !tested ? 'Test this controller in WoW' : 'Open controller';
  return { steps, complete: steps.filter(step => step.done).length, route, action, ready, tested };
}
