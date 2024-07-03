#!/usr/bin/env ucode
'use strict';
import * as uloop from "uloop";
import * as libubus from "ubus";

uloop.init();
let ubus = libubus.connect();

let interfaces = {};
let ssids = {};
let cache = {};
let sub_6g = [];
let sub_6g_obj;
let reload_timer;
let gc_timer;

let timeout = 48 * 60 * 60;

function event_cb_6g(ifname, req) {
	if (req.type == "coa")
		return 0;

	if (req.type == "probe")
		return 0;

	let addr = req.data.address;
	let iface = interfaces[ifname];
	if (!iface)
		return 0;

	let ssid = iface.ssid;
	if (!ssid)
		return 0;

	let ssid_cache = cache[ssid];
	if (ssid_cache && ssid_cache[addr])
		return 0;

	warn(`Drop ${req.type} on ${ifname} from ${addr}\n`);
	return 5;
}

function create_6g_subscriber() {
	for (let cur_sub in sub_6g)
		cur_sub.remove();
	sub_6g = [];

	for (let ifname, iface in interfaces) {
		if (iface.band != "6g")
			continue;

		let obj = "hostapd."+ifname;
		let cur_sub = ubus.subscriber((req) => event_cb_6g(ifname, req));
		cur_sub.subscribe(obj);
		push(sub_6g, cur_sub);
		ubus.call(obj, "notify_response", { notify_response: 1 });
	}
}

function cache_gc() {
	let ts = time();

	for (let ssid in keys(cache)) {
		if (!ssids[ssid]) {
			delete cache[ssid];
			continue;
		}

		let ssid_cache = cache[ssid];
		ssid = ssids[ssid];

		for (let addr in keys(ssid_cache)) {
			let sta = ssid_cache[addr];
			let keep = ts < cache.timeout;

			if (keep && !ssid.keys[sta.key])
				keep = false;
			if (keep)
				sta.keydata = ssid.keys[sta.key];
			if (!keep)
				delete cache[addr];
		}
	}
}

function netifd_reload() {
	let data = ubus.call("network.wireless", "status");

	ssids = {};
	interfaces = {};

	for (let radio_name, radio in data) {
		if (!radio.up)
			continue;

		for (let iface in radio.interfaces) {
			let config = iface.config;

			if (config.mode != "ap" || !iface.ifname)
				continue;

			let band = radio.config.band;
			let nr_data = ubus.call("hostapd."+iface.ifname, "rrm_nr_get_own");
			let nr;
			if (nr_data && nr_data.value && nr_data.value[2])
				nr = nr_data.value[2];
			interfaces[iface.ifname] = {
				band, nr,
				ssid: config.ssid,
			};

			ssids[config.ssid] ??= {
				interfaces: [],
				keys: {},
				bands: {},
			};
			let ssid = ssids[config.ssid];

			push(ssid.interfaces, iface.ifname);
			ssid.bands[band] = iface.ifname;
			for (let sta in iface.stations) {
				let stacfg = sta.config;

				let key = stacfg.key;
				if (!key)
					continue;

				let keydata = {};
				let vid = stacfg.vid;
				if (vid)
					keydata.vlan = +vid;

				ssid.keys[key] = keydata;
			}
		}
	}
	warn(sprintf("New config: %.J\n", { ssids, interfaces }));
	cache_gc();
	create_6g_subscriber();
}

function iface_ssid(ifname) {
	let iface = interfaces[ifname];
	if (!iface)
		return;

	return iface.ssid;
}

function sta_cache_entry_get(ssid, addr) {
	let ssid_cache = cache[ssid] ?? {};

	let entry = ssid_cache[addr];
	if (entry)
		entry.timeout = time() + timeout;

	warn(`Get cache entry ssid=${ssid} addr=${addr}: ${entry}\n`);
	return entry;
}

function sta_cache_entry_add(ssid, addr, key) {
	cache[ssid] ??= {};
	let ssid_cache = cache[ssid];
	let ssid_data = ssids[ssid];
	let keydata = ssid_data.keys[key];

	let cache_data = {
		timeout: time() + timeout,
		ssid, key,
		data: keydata ?? {},
	};
	ssid_cache[addr] = cache_data;
	warn(`Added cache entry ssid=${ssid} addr=${addr}\n`);
	return cache_data;
}

function ssid_psk(ssid) {
	ssid = ssids[ssid];
	if (!ssid)
		return [];

	return keys(ssid.keys);
}

function sta_auth_psk(ifname, addr) {
	let ssid = iface_ssid(ifname);
	if (!ssid)
		return;

	let cache = sta_cache_entry_get(ssid, addr);
	if (cache)
		return [ cache.key ];

	return ssid_psk(ssid);
}

function sta_auth_cache(ifname, addr, idx) {
	let ssid = iface_ssid(ifname);
	if (!ssid)
		return;

	let cache = sta_cache_entry_get(ssid, addr);
	if (cache)
		return cache.data;

	let psk = ssid_psk(ssid);
	if (!psk)
		return;

	psk = psk[idx];
	if (!psk)
		return;

	cache = sta_cache_entry_add(ssid, addr, psk);
	if (!cache)
		return;

	let ssid_data = ssids[ssid];
	if (!ssid_data)
		return cache.data;

	let target_ifname = ssid_data.bands["6g"];
	if (!target_ifname)
		return cache.data;

	let target_iface = interfaces[target_ifname];
	if (!target_iface)
		return cache.data;

	cache.timer = uloop.timer(5000, () => {
		let msg = {
			addr,
			disassociation_imminent: false,
			neighbors: [
				target_iface.nr
			],
			abridged: false,
		};
		ubus.call("hostapd."+ifname, "bss_transition_request", msg);
		delete cache.timer;
	});

	return cache.data;
}

function auth_cb(msg) {
	let data = msg.data;

	warn(`Event ${msg.type}: ${msg.data}\n`);
	switch (msg.type) {
	case "sta_auth":
		return {
			psk: sta_auth_psk(data.iface, data.sta),
			force_psk: true,
		};
	case "sta_connected":
		if (data.psk_idx == null)
			return;
		return sta_auth_cache(data.iface, data.sta, data.psk_idx - 1);
	case "reload":
		netifd_reload();
		reload_timer.set(5000);
		break;
	}
}

reload_timer = uloop.timer(-1, () => { netifd_reload(); });
gc_timer = uloop.timer(1000, () => { gc_timer.set(30 * 1000); cache_gc(); });
let sub = ubus.subscriber(auth_cb);
let listener = ubus.listener("ubus.object.add", (event, msg) => {
	if (msg.path == "hostapd-auth")
		sub.subscribe(msg.path);
});
sub.subscribe("hostapd-auth");
netifd_reload();
uloop.run();
