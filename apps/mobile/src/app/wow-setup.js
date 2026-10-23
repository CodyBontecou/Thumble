import { Linking, Text, View } from 'react-native';
import { Button, Columns, Eyebrow, Page, ui } from '../ui/design';
export default function WowSetupScreen() {
  return <Page><Columns><View style={ui.column}><Eyebrow>THUMBLE × CONSOLEPORT</Eyebrow><Text accessibilityRole="header" style={ui.title}>{'Your character.\nYour controls.'}</Text><Text style={ui.body}>Connect your Mac, prepare ConsolePort, and make your character’s actions feel at home on your phone.</Text><Button secondary onPress={() => Linking.openURL('https://www.curseforge.com/wow/addons/console-port')}>Get ConsolePort ↗</Button><Text style={ui.small}>The AI only builds the layout. Every button press is you.</Text></View>
    <View style={ui.column}>{[
      ['01 / PREPARE YOUR MAC', 'Connect before you launch.', 'Open Tapping Receiver, pair your phone on the same Wi-Fi, and verify the virtual gamepad before starting WoW.'],
      ['02 / CONSOLEPORT', 'Bring your actions together.', 'Install the ConsolePort release that matches your WoW installation. Restart WoW and follow its controller setup.'],
      ['03 / MAKE IT YOURS', 'Review. Apply. Play.', 'Use Thumble Bridge to export your character’s bindings. Your agent can propose a layout and spell bindings; review and apply them in-game. Test movement, camera, and modifiers before playing.'],
    ].map(([label, title, body]) => <View key={label} style={ui.card}><Eyebrow>{label}</Eyebrow><Text style={ui.heading}>{title}</Text><Text style={ui.body}>{body}</Text></View>)}</View>
  </Columns></Page>;
}
