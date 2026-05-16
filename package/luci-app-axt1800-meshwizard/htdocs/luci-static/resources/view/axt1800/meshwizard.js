'use strict';
'require view';
'require form';
'require uci';
'require ui';
'require rpc';

/*
 * AXT-1800 OpenMANET mesh setup wizard.
 *
 * Companion to the HaLow wizards in luci-app-ekhwizards / luci-app-
 * morseapwizard — those tightly couple to Morse-Micro JS modules that
 * aren't available on a non-HaLow build, so this is a parallel UI for
 * the AXT-1800's stock WiFi 6 + batman-adv setup.
 *
 * What it does:
 *   - Edits wireless.mesh0 (the 802.11s wifi-iface our uci-defaults
 *     creates on first boot) — mesh ID, encryption, passphrase.
 *   - Edits the 5 GHz wifi-device — channel, country code.
 *   - Optionally enables the 5 GHz AP wifi-iface (disabled by our
 *     uci-defaults) and gives it an SSID for client devices.
 *   - Sets the country code on both radios at once.
 *
 * Doesn't touch:
 *   - network.bat0 / mesh_hardif (already set up by uci-defaults).
 *   - openmanetd / alfred (their config is independent).
 *   - Firewall / DHCP.
 */

const COUNTRIES = [
	['00', 'World (default, restricted)'],
	['US', 'United States'],
	['CA', 'Canada'],
	['GB', 'United Kingdom'],
	['IE', 'Ireland'],
	['DE', 'Germany'],
	['FR', 'France'],
	['NL', 'Netherlands'],
	['ES', 'Spain'],
	['IT', 'Italy'],
	['SE', 'Sweden'],
	['NO', 'Norway'],
	['CH', 'Switzerland'],
	['AT', 'Austria'],
	['PL', 'Poland'],
	['AU', 'Australia'],
	['NZ', 'New Zealand'],
	['JP', 'Japan'],
	['KR', 'South Korea'],
	['SG', 'Singapore'],
	['HK', 'Hong Kong'],
	['IL', 'Israel'],
];

const CHANNELS_5G = [
	['36',  '36 — 5180 MHz (non-DFS)'],
	['40',  '40 — 5200 MHz (non-DFS)'],
	['44',  '44 — 5220 MHz (non-DFS)'],
	['48',  '48 — 5240 MHz (non-DFS)'],
	['149', '149 — 5745 MHz (non-DFS)'],
	['153', '153 — 5765 MHz (non-DFS)'],
	['157', '157 — 5785 MHz (non-DFS)'],
	['161', '161 — 5805 MHz (non-DFS)'],
	['165', '165 — 5825 MHz (non-DFS)'],
];

function findRadioByBand(band) {
	let found = null;
	uci.sections('wireless', 'wifi-device', function(s) {
		if (s.band === band) found = s['.name'];
	});
	return found;
}

function findApIfaceForRadio(radio) {
	let found = null;
	uci.sections('wireless', 'wifi-iface', function(s) {
		if (s.device === radio && s.mode === 'ap') found = s['.name'];
	});
	return found;
}

return view.extend({
	load: function() {
		return Promise.all([
			uci.load('wireless'),
			uci.load('network'),
			uci.load('system'),
		]);
	},

	render: function() {
		const radio5g = findRadioByBand('5g');
		const radio2g = findRadioByBand('2g');
		const ap5g = radio5g ? findApIfaceForRadio(radio5g) : null;
		const ap2g = radio2g ? findApIfaceForRadio(radio2g) : null;

		const m = new form.Map('wireless', _('AXT-1800 Mesh Wizard'),
			_('Configure the 802.11s mesh on the 5 GHz radio plus optional access-point side. Other AXT-1800 nodes on the same Mesh ID, channel, and key will peer automatically; batman-adv is already wired up on top of the mesh.'));

		// --- Section 1: mesh ---
		let s, o;
		s = m.section(form.NamedSection, 'mesh0', 'wifi-iface', _('Mesh'));
		s.anonymous = true;

		o = s.option(form.Value, 'mesh_id', _('Mesh ID'),
			_('Must match on every node in this mesh. Treated as a network identifier, not a secret.'));
		o.placeholder = 'openmanet-mesh';
		o.rmempty = false;

		if (radio5g) {
			o = s.option(form.ListValue, '_channel', _('5 GHz Channel'),
				_('Stick to non-DFS channels (no radar avoidance pause on bring-up).'));
			for (const [val, label] of CHANNELS_5G) o.value(val, label);
			o.load = () => uci.get('wireless', radio5g, 'channel') || '36';
			o.write = (sid, val) => uci.set('wireless', radio5g, 'channel', val);
		}

		o = s.option(form.ListValue, 'encryption', _('Encryption'),
			_('SAE = WPA3 authentication for mesh peers (requires wpad). All peers must use the same key.'));
		o.value('none', _('None (open mesh)'));
		o.value('sae',  _('SAE (WPA3)'));
		o.default = 'none';

		o = s.option(form.Value, 'key', _('Passphrase'),
			_('8–63 characters. Must match on all peers.'));
		o.password = true;
		o.depends('encryption', 'sae');
		o.datatype = 'wpakey';
		o.rmempty = true;

		// --- Section 2: regulatory ---
		if (radio5g || radio2g) {
			s = m.section(form.TypedSection, '_regulatory', _('Regulatory'));
			s.anonymous = true;
			s.cfgsections = () => ['_regulatory'];

			o = s.option(form.ListValue, '_country', _('Country Code'),
				_('Sets the regulatory domain on both radios. Required for full TX power and to unlock all channels in your region.'));
			for (const [val, label] of COUNTRIES) o.value(val, label);
			o.load = () => (radio5g && uci.get('wireless', radio5g, 'country')) ||
			               (radio2g && uci.get('wireless', radio2g, 'country')) || '00';
			o.write = (sid, val) => {
				if (radio5g) uci.set('wireless', radio5g, 'country', val);
				if (radio2g) uci.set('wireless', radio2g, 'country', val);
			};
		}

		// --- Section 3: optional 5 GHz access point ---
		if (ap5g) {
			s = m.section(form.NamedSection, ap5g, 'wifi-iface',
				_('5 GHz Access Point (optional)'),
				_('Disabled by default so the radio is dedicated to the mesh. Enable to also serve client devices over 5 GHz on the same channel as the mesh.'));
			s.anonymous = true;

			o = s.option(form.Flag, 'disabled', _('Disable AP'));
			o.default = '1';
			o.rmempty = false;

			o = s.option(form.Value, 'ssid', _('SSID'));
			o.depends('disabled', '0');
			o.placeholder = 'OpenMANET-AXT';

			o = s.option(form.ListValue, 'encryption', _('AP Encryption'));
			o.depends('disabled', '0');
			o.value('none', _('Open'));
			o.value('psk2', _('WPA2-PSK'));
			o.value('sae',  _('WPA3 SAE'));
			o.value('sae-mixed', _('WPA2/WPA3 mixed'));
			o.default = 'sae-mixed';

			o = s.option(form.Value, 'key', _('AP Passphrase'));
			o.password = true;
			o.depends({ disabled: '0', '!contains': true, encryption: 'sae' });
			o.depends({ disabled: '0', '!contains': true, encryption: 'psk' });
			o.datatype = 'wpakey';
		}

		// --- Section 4: optional 2.4 GHz access point ---
		if (ap2g) {
			s = m.section(form.NamedSection, ap2g, 'wifi-iface',
				_('2.4 GHz Access Point (optional)'),
				_('The 2.4 GHz radio is independent of the mesh. Useful for legacy client devices.'));
			s.anonymous = true;

			o = s.option(form.Flag, 'disabled', _('Disable AP'));
			o.default = '1';
			o.rmempty = false;

			o = s.option(form.Value, 'ssid', _('SSID'));
			o.depends('disabled', '0');
			o.placeholder = 'OpenMANET-AXT-2G';

			o = s.option(form.ListValue, 'encryption', _('AP Encryption'));
			o.depends('disabled', '0');
			o.value('none', _('Open'));
			o.value('psk2', _('WPA2-PSK'));
			o.value('sae-mixed', _('WPA2/WPA3 mixed'));
			o.default = 'sae-mixed';

			o = s.option(form.Value, 'key', _('AP Passphrase'));
			o.password = true;
			o.depends({ disabled: '0', '!contains': true, encryption: 'sae' });
			o.depends({ disabled: '0', '!contains': true, encryption: 'psk' });
			o.datatype = 'wpakey';

			// Enable the 2.4 GHz radio if the user enables the AP
			o = s.option(form.HiddenValue, '_radio2g_enable');
			o.write = function(sid, _val) {
				const dis = this.section.formvalue(sid, 'disabled');
				if (dis === '0' && radio2g) {
					uci.set('wireless', radio2g, 'disabled', '0');
				}
			};
		}

		return m.render();
	}
});
