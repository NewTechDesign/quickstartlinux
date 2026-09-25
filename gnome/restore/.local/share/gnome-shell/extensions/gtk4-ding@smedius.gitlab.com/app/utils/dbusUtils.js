/* eslint-disable no-template-curly-in-string */

/* DING: Desktop Icons New Generation for GNOME Shell
 *
 * Copyright (C) 2019-2022 Sergio Costas (rastersoft@gmail.com)
 * Based on code original (C) Carlos Soriano
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, version 3 of the License.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <http://www.gnu.org/licenses/>.
 */
import {Gdk, Gio, GLib, GdkWayland} from '../../dependencies/gi.js';
import {DBusInterfaces, GsConnect} from '../../dependencies/localFiles.js';
import {_} from '../../dependencies/gettext.js';

const Signals = imports.signals;

export {DBusUtils};
class ProxyManager {
    /*
    This class manages a DBus object through a DBusProxy. Any access to the
    proxy when the object isn't available results in a notification specifying
    that an specific program is needed to run that option.

    The proxy itself is accessed through the 'proxy' property (read-only).
    Any access to it will check the availability and show the notification if
    it isn't available. To get access to it without triggering this, it is
    possible to use the 'proxyNoCheck' property.

    Whether the object is or not available can be checked with the
    'isAvailable' property. Also, every time the availability changes,
    the signal 'changed-status' is emitted.
    */
    constructor(
        dbusManager,
        serviceName,
        objectName,
        interfaceName,
        inSystemBus,
        programNeeded,
        makeAsync = true,
        nocomplaint = false
    ) {
        this._dbusManager = dbusManager;
        this._serviceName = serviceName;
        this._objectName = objectName;
        this._interfaceName = interfaceName;
        this._inSystemBus = inSystemBus;
        this._nocomplaint = nocomplaint;
        this._signals = {};
        this._signalsIDs = {};
        this._connectSignals = {};
        this._connectSignalsIDs = {};

        if (typeof programNeeded === 'string') {
            // if 'programNeeded' is a string, create a generic message
            // for the notification.
            this._programNeeded = [
                _('"${programName}" is not available')
                .replace('${programName}', programNeeded),
                _(
                    'Install "${programName}" to enable ' +
                    'Desktop Icons to perform these actions.'
                )
                .replace('${programName}', programNeeded),
            ];
        } else {
            // instead, if it's not, it is presumed to be an array with two
            // sentences, one for the notification title and another for
            // the main text.
            this._programNeeded = programNeeded;
        }

        this._timeout = 0;
        this._available = false;
        this._proxy = null;

        dbusManager.connect(
            inSystemBus
                ? 'changed-availability-system'
                : 'changed-availability-local',
            () => {
                this._makeProxy(makeAsync);
            }
        );

        this._makeProxy(makeAsync);
    }

    async _makeProxy(makeAsync) {
        const newAvailability =
            this._dbusManager
            .checkIsAvailable(this._serviceName, this._inSystemBus);

        if (newAvailability !== this._available) {
            if (newAvailability) {
                if (makeAsync)
                    await this.makeNewProxyAsync().catch(e => console.error(e));
                else
                    this.makeNewProxySync();
            } else {
                this._available = false;
                this._proxy = null;
            }

            this.emit('changed-status', this._available);
        }
    }

    connectSignalToProxy(signal, cb) {
        this._connectSignals[signal] = cb;

        if (this._proxy) {
            this._connectSignalsIDs[signal] =
            this._proxy.connectSignal(signal, cb);
        }
    }

    connectToProxy(signal, cb) {
        this._signals[signal] = cb;

        if (this._proxy)
            this._signalsIDs[signal] = this._proxy.connect(signal, cb);
    }

    disconnectFromProxy(signal) {
        if (signal in this._signalsIDs) {
            if (this._proxy)
                this._proxy.disconnect(this._signalsIDs[signal]);

            delete this._signalsIDs[signal];
            delete this._signals[signal];
        }
    }

    disconnectSignalFromProxy(signal) {
        if (signal in this._connectSignalsIDs) {
            if (this._proxy)
                this._proxy.disconnectSignal(this._connectSignalsIDs[signal]);

            delete this._connectSignalsIDs[signal];
            delete this._connectSignals[signal];
        }
    }

    makeNewProxySync() {
        const interfaceXML =
            this._dbusManager
            .getInterface(
                this._serviceName,
                this._objectName,
                this._interfaceName,
                this._inSystemBus,
                false
            );

        if (interfaceXML) {
            const targetproxy =
                Gio.DBusProxy.makeProxyWrapper(interfaceXML);

            try {
                this._proxy = new targetproxy(
                    this._inSystemBus ? Gio.DBus.system : Gio.DBus.session,
                    this._serviceName,
                    this._objectName,
                    null
                );

                for (let signal in this._signals) {
                    this._signalsIDs[signal] =
                        this._proxy.connect(signal, this._signals[signal]);
                }

                for (let signal in this._connectSignals) {
                    this._connectSignalsIDs[signal] =
                        this._proxy.connectSignal(
                            signal,
                            this._connectSignals[signal]
                        );
                }

                this._available = true;

                return true;
            } catch (e) {
                this._available = false;
                this._proxy = null;
                this._signalIDs = {};
                this._connectSignalsIDs = {};

                console.log(
                    `Error creating proxy, ${this._programNeeded[0]}:` +
                    ` ${e.message}\n${e.stack}`
                );

                return false;
            }
        } else {
            this._available = false;
            this._proxy = null;
            this._signalIDs = {};
            this._connectSignalsIDs = {};

            return false;
        }
    }

    makeNewProxyAsync(cancellable = null, flags = Gio.DBusProxyFlags.NONE) {
        return new Promise(resolve => {
            const interfaceXML =
                this._dbusManager
                .getInterface(
                    this._serviceName,
                    this._objectName,
                    this._interfaceName,
                    this._inSystemBus,
                    false
                );

            if (interfaceXML) {
                const targetproxy =
                    Gio.DBusProxy.makeProxyWrapper(interfaceXML);

                try {
                    new targetproxy(
                        this._inSystemBus ? Gio.DBus.system : Gio.DBus.session,
                        this._serviceName,
                        this._objectName,
                        (proxy, error) => {
                            if (error === null) {
                                for (let signal in this._signals) {
                                    this._signalsIDs[signal] =
                                        proxy.connect(
                                            signal,
                                            this._signals[signal]
                                        );
                                }

                                for (let signal in this._connectSignals) {
                                    this._connectSignalsIDs[signal] =
                                        proxy.connectSignal(
                                            signal,
                                            this._connectSignals[signal]
                                        );
                                }

                                this._available = true;
                                this._proxy = proxy;

                                resolve(true);
                            } else {
                                this._available = false;
                                this._proxy = null;

                                resolve(false);
                            }
                        },
                        cancellable,
                        flags
                    );
                } catch (e) {
                    this._available = false;
                    this._proxy = null;
                    console.log(
                        `Error creating proxy, ${this._programNeeded[0]}:` +
                        ` ${e.message}\n${e.stack}`
                    );

                    resolve(false);
                }
            } else {
                this._available = false;
                this._proxy = null;
                resolve(false);
            }
        });
    }

    notify(message1, message2) {
        this._dbusManager.doNotify(message1, message2);
    }

    notifyUnavailable() {
        if (!this._programNeeded)
            return;

        console.log(this._programNeeded[0]);
        console.log(this._programNeeded[1]);

        this._dbusManager
        .doNotify(this._programNeeded[0], this._programNeeded[1]);
    }

    get isAvailable() {
        return !!this._proxy;
    }

    get proxyNoCheck() {
        return this._proxy;
    }

    get proxy() {
        if (!this._available || !this._proxy) {
            if (this._nocomplaint)
                return false;

            if (this._timeout === 0) {
                this.notifyUnavailable();
                this._timeout = GLib.timeout_add(
                    GLib.PRIORITY_DEFAULT,
                    1000,
                    () => {
                        this._timeout = 0;
                        return false;
                    }
                );
            }
        }

        return this._proxy;
    }
}
Signals.addSignalMethods(ProxyManager.prototype);


class DBusManager {
    /*
    This class manages all the DBus operations. A ProxyManager() class can
    subscribe to this to be notified whenever a change in the bus has occurred
    (like a server has been added or removed). It also can ask
    for a DBus interface, either getting it from the dbusInterfaces.js file
    or using DBus Introspection (which allows to get the currently available
    interface and, that way, know if an object implements an specific
    method, property or signal).

    ProxyManager() classes subscribe to the 'changed-availability-system'
    or 'changed-availability-local' signals, which are emitted every time a
    change in the bus or in the configuration files happen. Then, it can use
    checkIsAvailable() to determine if the desired service is available
    in the system or not.
    */
    constructor(mainApp) {
        this._mainApp = mainApp;
        this._availableInSystemBus = [];
        this._availableInLocalBus = [];
        this._pendingLocalSignal = false;
        this._pendingSystemSignal = false;
        this._signalTimerID = 0;

        const interfaceXML =
            this.getInterface(
                'org.freedesktop.DBus',
                '/org/freedesktop/DBus',
                'org.freedesktop.DBus',
                true, // system bus
                true
            ); // use DBus Introspection

        const dbusSystemProxy = Gio.DBusProxy.makeProxyWrapper(interfaceXML);

        this._dbusSystemProxy =
            new dbusSystemProxy(
                Gio.DBus.system,
                'org.freedesktop.DBus',
                '/org/freedesktop/DBus',
                null
            );

        let ASCinSystemBus =
            interfaceXML.includes('ActivatableServicesChanged');

        // Don't presume that both system and local have the same
        // interface (just in case)
        const localInterfaceXML = this.getInterface(
            'org.freedesktop.DBus',
            '/org/freedesktop/DBus',
            'org.freedesktop.DBus',
            false, // local bus
            true); // use DBus Introspection

        const dbusLocalProxy = Gio.DBusProxy.makeProxyWrapper(localInterfaceXML);

        this._dbusLocalProxy = new dbusLocalProxy(
            Gio.DBus.session,
            'org.freedesktop.DBus',
            '/org/freedesktop/DBus',
            null
        );

        const ASCinLocalBus = localInterfaceXML.includes('ActivatableServicesChanged');

        this._updateAllAvailabilities();

        this._dbusLocalProxy.connectSignal('NameOwnerChanged', () => {
            this._emitChangedSignal(true);
        });

        if (ASCinLocalBus) {
            this._dbusLocalProxy.connectSignal(
                'ActivatableServicesChanged',
                () => {
                    this._emitChangedSignal(true);
                }
            );
        }
        this._dbusSystemProxy.connectSignal('NameOwnerChanged', () => {
            this._emitChangedSignal(false);
        });

        if (ASCinSystemBus) {
            this._dbusSystemProxy.connectSignal(
                'ActivatableServicesChanged',
                () => {
                    this._emitChangedSignal(false);
                }
            );
        }

        const notifyInterfaceXML = this.getInterface(
            'org.freedesktop.Notifications',
            '/org/freedesktop/Notifications',
            'org.freedesktop.Notifications',
            false, // local bus
            false); // get interface from local code

        const notifyProxy = Gio.DBusProxy.makeProxyWrapper(notifyInterfaceXML);
        this._notifyProxy =
            new notifyProxy(
                Gio.DBus.session,
                'org.freedesktop.Notifications',
                '/org/freedesktop/Notifications',
                null
            );
    }

    _emitChangedSignal(localDBus) {
        if (localDBus)
            this._pendingLocalSignal = true;
        else
            this._pendingSystemSignal = true;

        if (this._signalTimerID)
            GLib.source_remove(this._signalTimerID);

        this._signalTimerID =
            GLib.timeout_add(
                GLib.PRIORITY_DEFAULT,
                1000,
                () => {
                    this._signalTimerID = 0;
                    this._updateAllAvailabilities();

                    if (this._pendingLocalSignal)
                        this.emit('changed-availability-local');

                    if (this._pendingSystemSignal)
                        this.emit('changed-availability-system');

                    this._pendingLocalSignal = false;
                    this._pendingSystemSignal = false;

                    return false;
                }
            );
    }

    checkIsAvailable(serviceName, inSystemBus) {
        if (inSystemBus)
            return this._availableInSystemBus.includes(serviceName);
        else
            return this._availableInLocalBus.includes(serviceName);
    }

    _updateAllAvailabilities() {
        this._availableInLocalBus =
            this._updateAvailability(this._dbusLocalProxy);

        this._availableInSystemBus =
            this._updateAvailability(this._dbusSystemProxy);
    }

    _updateAvailability(proxy) {
        // We read both the well-known names actually running and those
        // available as activatables, and generate a single list with both.
        // Thus a service will be "enabled" if it is running
        // or if it is activatable.
        let availableNames = [];
        let names = proxy.ListNamesSync();

        for (let n of names[0]) {
            if (n.startsWith(':'))
                continue;

            if (!(n in availableNames))
                availableNames.push(n);
        }

        let names2 = proxy.ListActivatableNamesSync();

        for (let n of names2[0]) {
            if (n.startsWith(':'))
                continue;

            if (!(n in availableNames))
                availableNames.push(n);
        }

        return availableNames;
    }

    _getNextTag() {
        this._xmlIndex++;
        let pos = this._xmlData.indexOf('<', this._xmlIndex);

        if (pos === -1)
            return null;

        let pos2 = this._xmlData.indexOf('>', pos);

        if (pos2 === -1)
            return null;

        this._xmlIndex = pos;

        return this._xmlData.substring(pos + 1, pos2).trim();
    }

    /*
    Extracts the XML definition for an interface from the raw data
    returned by DBus Introspection. This is needed because DBus Introspection
    returns a single XML file with all the interfaces supported by an object,
    while DBusProxyWrapper requires an XML with only the desired interface.
     */
    _parseXML(data, interfaceName) {
        this._xmlIndex = -1;
        this._xmlData = data;
        let tag;

        while (true) {
            tag = this._getNextTag();

            if (tag === null)
                return null;

            if (!tag.startsWith('interface '))
                continue;

            if (tag.includes(interfaceName))
                break;
        }

        const start = this._xmlIndex;

        while (true) {
            tag = this._getNextTag();

            if (tag === null)
                return null;

            if (!tag.startsWith('/interface'))
                continue;

            break;
        }

        const end = 1 + data.indexOf('>', this._xmlIndex);

        return (
            `<node>
             ${data.substring(start, end)}
            </node>`
        );
    }

    getInterface(
        serviceName,
        objectName,
        interfaceName,
        inSystemBus,
        forceIntrospection
    ) {
        if ((interfaceName in DBusInterfaces.DBusInterfaces) &&
            !forceIntrospection
        ) {
            return DBusInterfaces.DBusInterfaces[interfaceName];
        } else {
            let data =
                this.getIntrospectionData(serviceName, objectName, inSystemBus);

            if (data === null)
                return null;
            else
                return this._parseXML(data, interfaceName);
        }
    }

    getIntrospectionData(serviceName, objectName, inSystemBus) {
        let data = null;

        try {
            const IntrospectionProxy =
                Gio.DBusProxy.makeProxyWrapper(
                    DBusInterfaces
                    .DBusInterfaces['org.freedesktop.DBus.Introspectable']
                );
            const wrapper =
                new IntrospectionProxy(
                    inSystemBus ? Gio.DBus.system : Gio.DBus.session,
                    serviceName,
                    objectName,
                    null
                );

            data = wrapper.IntrospectSync()[0];
        } catch (e) {
            let message = e.message;

            if (!message.includes('org.gnome.Shell.Extensions.GSConnect')) {
                console.log(
                    'Error getting introspection data over Dbus: ' +
                    `${e.message}\n${e.stack}`
                );
            }

            return null;
        }

        if (data === null)
            return null;

        if (!data.includes('interface'))
            return null; // if it doesn't exist, return null

        return data;
    }

    doNotify(header, text) {
        /*
            The freedesktop specificaton specifies these common icons by name
            be available in compatible themes, including displayImange and
            appIcon
        */
        const displayImage =
            'file:///usr/share/icons/Adwaita/scalable/devices/computer.svg';

        const appID = this._mainApp.get_application_id();

        const notifyHint =  {
            'image-path': new GLib.Variant('s', displayImage),
            'desktop-entry': new GLib.Variant('s', appID),
        };

        const appName = 'Desktop Icons';
        const notifictionID = 0;
        // from freeDesktop icon theme specification which should be available
        // for this interface
        const appIcon = 'computer';
        const actions = [];
        const displayTime = 1000; // 1 second

        this._notifyProxy.NotifyRemote(
            appName,
            notifictionID,
            appIcon,
            header,
            text,
            actions,
            notifyHint,
            displayTime,
            () => {}
        );
    }
}
Signals.addSignalMethods(DBusManager.prototype);


class DbusOperationsManager {
    constructor(
        FreeDesktopFileManager,
        GnomeArchiveManager
    ) {
        this.freeDesktopFileManager = FreeDesktopFileManager;
        this.gnomeArchiveManager = GnomeArchiveManager;

        this._monitorExtractionSupportedTypes();
    }

    _monitorExtractionSupportedTypes() {
        this.decompressibleTypes = [];

        this.archiveConnectionId =
            this.gnomeArchiveManager.connect(
                'changed-status',
                (_actor, available) => {
                    if (available) {
                        // wait a second to ensure that everything has settled
                        GLib.timeout_add(GLib.PRIORITY_DEFAULT, 1000, () => {
                            try {
                                this._getExtractionSupportedTypes();
                            } catch (e) {}
                            return false;
                        });
                    } else {
                        this.decompressibleTypes = [];
                    }
                }
            );

        if (this.gnomeArchiveManager.isAvailable)
            this._getExtractionSupportedTypes();
    }

    _getExtractionSupportedTypes() {
        this.decompressibleTypes = [];
        const archiveProxy = this.gnomeArchiveManager.proxy;

        try {
            archiveProxy?.GetSupportedTypesRemote(
                'extract',
                (result, error) => {
                    if (error) {
                        console.log(
                            'Can not get the extractable types:' +
                            ` ${error.message}.` +
                            `\nEnsure that File-Roller is installed.\n${error}.`
                        );
                        return;
                    }
                    for (let key of result.values()) {
                        for (let type of key.values()) {
                            this.decompressibleTypes
                                .push(Object.values(type)[0]);
                        }
                    }
                }
            );
        } catch (e) {
            console.log(e.message, e.stack);
        }
    }

    _sendNoProxyError(callback) {
        if (callback) {
            GLib.idle_add(GLib.PRIORITY_LOW, () => {
                callback(null, 'noProxy');
                return false;
            });
        }
    }

    ShowItemPropertiesRemote(selection, timestamp, callback = null) {
        if (!this.freeDesktopFileManager.proxy) {
            this._sendNoProxyError(callback);
            return;
        }

        this.freeDesktopFileManager.proxy.ShowItemPropertiesRemote(
            selection,
            this._getStartupId(selection, timestamp),
            (result, error) => {
                if (callback)
                    callback(result, error);

                if (error)
                    console.log(`Error showing properties: ${error.message}`);
            }
        );
    }

    ShowItemsRemote(showInFilesList, timestamp, callback = null) {
        if (!this.freeDesktopFileManager.proxy) {
            this._sendNoProxyError(callback);

            return;
        }

        this.freeDesktopFileManager.proxy.ShowItemsRemote(
            showInFilesList,
            this._getStartupId(showInFilesList, timestamp),
            (result, error) => {
                if (callback)
                    callback(result, error);

                if (error) {
                    console.log(
                        `Error showing file on desktop: ${error.message}`
                    );
                }
            }
        );
    }

    ExtractRemote(extractFileItem, folder, boolean, callback = null) {
        if (!this.gnomeArchiveManager.proxy) {
            this._sendNoProxyError(callback);

            return;
        }

        this.gnomeArchiveManager.proxy.ExtractRemote(
            extractFileItem,
            folder,
            true,
            (result, error) => {
                if (callback)
                    callback(result, error);

                if (error)
                    console.log(`Error extracting files: ${error.message}`);
            });
    }

    CompressRemote(compressFileItems, folder, boolean, callback = null) {
        if (!this.gnomeArchiveManager.proxy) {
            this._sendNoProxyError(callback);

            return;
        }

        this.gnomeArchiveManager.proxy.CompressRemote(
            compressFileItems,
            folder,
            boolean,
            (result, error) => {
                if (callback)
                    callback(result, error);

                if (error)
                    console.log(`Error compressing files: ${error.message}`);
            }
        );
    }

    _getStartupId(fileUris, timestamp) {
        if (!timestamp)
            return '';

        const context = Gdk.Display.get_default().get_app_launch_context();
        context.set_timestamp(timestamp);

        if (!this._fileManager) {
            this._fileManager =
                Gio.File.new_for_path('/')
                .query_default_handler(null);
        }

        return (
            context
            .get_startup_notify_id(
                this._fileManager,
                fileUris.map(uri => Gio.File.new_for_uri(uri))
            )
        );
    }
}


// All users of a surface share one export, including while export is pending.
// This also supports GTK before 4.12, which can only track one export per surface.
class PlatformDataManager {
    constructor() {
        this._surfaces = new WeakMap();
    }

    async acquire(parentWindow, timestamp = Gdk.CURRENT_TIME) {
        let parentHandle = '';
        let freePlatformData = () => {};
        try {
            const surface = parentWindow?.get_surface();
            if (surface instanceof GdkWayland.WaylandToplevel) {
                const lease = await this._acquireHandle(surface);
                parentHandle = `wayland:${lease.handle}`;
                freePlatformData = lease.release;
            }
        } catch (error) {
            console.error(error, 'Impossible to determine the parent window');
        }

        try {
            return {
                data: {
                    'parent-handle': new GLib.Variant('s', parentHandle),
                    'timestamp': new GLib.Variant('u', timestamp),
                    'window-position': new GLib.Variant('s', 'center'),
                },
                parentHandle,
                freePlatformData,
            };
        } catch (error) {
            freePlatformData();
            throw error;
        }
    }

    async _acquireHandle(surface) {
        let entry = this._surfaces.get(surface);
        if (!entry) {
            entry = {users: 0, handle: null};
            this._surfaces.set(surface, entry);
            entry.ready = new Promise((resolve, reject) => {
                surface.export_handle((_surface, handle) => {
                    if (handle) {
                        entry.handle = handle;
                        resolve();
                    } else {
                        reject(new Error('Could not export Wayland surface'));
                    }
                });
            });
        }

        entry.users++;
        let released = false;
        const release = () => {
            if (released)
                return;
            released = true;
            if (--entry.users !== 0)
                return;

            this._surfaces.delete(surface);
            if (!entry.handle)
                return;
            if (typeof surface.drop_exported_handle === 'function')
                surface.drop_exported_handle(entry.handle);
            else
                surface.unexport_handle();
        };

        try {
            await entry.ready;
            return {handle: entry.handle, release};
        } catch (error) {
            release();
            throw error;
        }
    }
}

class RemoteFileOperationsManager extends DbusOperationsManager {
    constructor(
        fileOperationsManager,
        FreeDesktopFileManager,
        GnomeNautilusPreview,
        GnomeArchiveManager,
        mainApp
    ) {
        super(
            FreeDesktopFileManager,
            GnomeArchiveManager
        );

        this.mainApp = mainApp;
        this.fileOperationsManager = fileOperationsManager;
        this.gnomeNautilusPreviewManager = GnomeNautilusPreview;
        this._platformDataManager = new PlatformDataManager();
        this.fileOperationsManager.createPlatformData = this.createPlatformData.bind(this);
        this._previewRequest = 0;
        this.previewParentHandle = null;
        GnomeNautilusPreview.connectToProxy('g-properties-changed', proxy => {
            this._previewPropertiesReceived = true;
            this._syncPreviewHandle(proxy);
        });
        GnomeNautilusPreview.connectToProxy('notify::g-name-owner', proxy => {
            if (this._previewData && !this._previewOwner && this._previewPending)
                this._previewOwner = proxy.g_name_owner;
            else if (this._previewData && proxy.g_name_owner !== this._previewOwner)
                this._releasePreviewHandle();
        });
        GnomeNautilusPreview.connect('changed-status', (_manager, available) => {
            if (!available)
                this._releasePreviewHandle();
        });
        mainApp.connect('shutdown', () => {
            this._previewRequest++;
            this._releasePreviewHandle();
        });
    }

    createPlatformData(event = null) {
        const parentWindow = event?.parentWindow ??
            this.mainApp.getDialogParentWindow?.() ?? null;
        const timestamp = event?.timestamp ?? Gdk.CURRENT_TIME;
        return this._platformDataManager.acquire(parentWindow, timestamp);
    }

    _releasePreviewHandle() {
        this._previewData?.freePlatformData();
        this._previewData = null;
        this.previewParentHandle = null;
        this._previewOwner = null;
    }

    _syncPreviewHandle(proxy) {
        if (this._previewData && !this._previewPending &&
            this._previewPropertiesReceived &&
            (!proxy.Visible || proxy.ParentHandle !== this.previewParentHandle))
            this._releasePreviewHandle();
    }

    async ShowFileRemote(uri, activationToken = '', boolean, event = null, callback = null) {
        const request = ++this._previewRequest;
        const proxy = this.gnomeNautilusPreviewManager.proxy;
        if (!proxy) {
            this._sendNoProxyError(callback);

            return;
        }

        const platformData = await this.createPlatformData(event);
        if (request !== this._previewRequest) {
            platformData.freePlatformData();
            return;
        }

        this._releasePreviewHandle();
        this._previewData = platformData;
        this._previewOwner = proxy.g_name_owner;
        this._previewPending = true;
        // Sushi queues PropertiesChanged; it can arrive after the method reply.
        // Until it arrives, the cached properties describe the previous preview.
        this._previewPropertiesReceived = false;
        this.previewParentHandle = platformData.parentHandle;
        try {
            proxy.ShowFileRemote(
                uri,
                platformData.parentHandle,
                boolean,
                activationToken,
                (result, error) => {
                    if (this._previewData === platformData) {
                        this._previewPending = false;
                        if (error)
                            this._releasePreviewHandle();
                        else
                            this._syncPreviewHandle(proxy);
                    }
                    if (callback)
                        callback(result, error);

                    if (error)
                        console.log(`Error previewing file: ${error.message}`);
                });
        } catch (error) {
            if (this._previewData === platformData)
                this._releasePreviewHandle();
            throw error;
        }
    }

    async MoveURIsRemote(fileList, uri, event = null, callback = null) {
        let platformData;
        try {
            if (!this.fileOperationsManager.proxy) {
                this._sendNoProxyError(callback);

                return;
            }

            platformData = await this.createPlatformData(event);

            this.fileOperationsManager.proxy.MoveURIsRemote(
                fileList,
                uri,
                platformData.data,
                (result, error) => {
                    platformData.freePlatformData();
                    if (callback)
                        callback(result, error);

                    if (error)
                        console.log(`Error moving files: ${error.message}`);
                }
            );
        } catch (e) {
            platformData?.freePlatformData();
            console.error(e);
        }
    }

    async CopyURIsRemote(fileList, uri, event = null, callback = null) {
        let platformData;
        try {
            if (!this.fileOperationsManager.proxy) {
                this._sendNoProxyError(callback);

                return;
            }

            platformData = await this.createPlatformData(event);

            this.fileOperationsManager.proxy.CopyURIsRemote(
                fileList,
                uri,
                platformData.data,
                (result, error) => {
                    platformData.freePlatformData();
                    if (callback)
                        callback(result, error);

                    if (error)
                        console.log(`Error copying files: ${error.message}`);
                }
            );
        } catch (e) {
            platformData?.freePlatformData();
            console.error(e);
        }
    }

    async RenameURIRemote(fileList, uri, event = null, callback = null) {
        let platformData;
        try {
            if (!this.fileOperationsManager.proxy) {
                this._sendNoProxyError(callback);

                return;
            }

            platformData = await this.createPlatformData(event);

            this.fileOperationsManager.proxy.RenameURIRemote(
                fileList,
                uri,
                platformData.data,
                (result, error) => {
                    platformData.freePlatformData();
                    if (callback)
                        callback(result, error);

                    if (error)
                        console.log(`Error copying files: ${error.message}`);
                }
            );
        } catch (e) {
            platformData?.freePlatformData();
            console.error(e);
        }
    }

    async TrashURIsRemote(fileList, event = null, callback = null) {
        let platformData;
        try {
            if (!this.fileOperationsManager.proxy) {
                this._sendNoProxyError(callback);

                return;
            }

            platformData = await this.createPlatformData(event);

            this.fileOperationsManager.proxy.TrashURIsRemote(
                fileList,
                platformData.data,
                (result, error) => {
                    platformData.freePlatformData();
                    if (callback)
                        callback(result, error);

                    if (error)
                        console.log(`Error Trashing files: ${error.message}`);
                }
            );
        } catch (e) {
            platformData?.freePlatformData();
            console.error(e);
        }
    }

    async DeleteURIsRemote(fileList, event = null, callback = null) {
        let platformData;
        try {
            if (!this.fileOperationsManager.proxy) {
                this._sendNoProxyError(callback);

                return;
            }

            platformData = await this.createPlatformData(event);

            this.fileOperationsManager.proxy.DeleteURIsRemote(
                fileList,
                platformData.data,
                (source, error) => {
                    platformData.freePlatformData();
                    if (callback)
                        callback(source, error);

                    if (error) {
                        console.log(
                            'Error deleting files on the desktop:' +
                            ` ${error.message}`
                        );
                    }
                }
            );
        } catch (e) {
            platformData?.freePlatformData();
            console.error(e);
        }
    }

    async EmptyTrashRemote(askConfirmation, event = null, callback = null) {
        let platformData;
        try {
            if (!this.fileOperationsManager.proxy) {
                this._sendNoProxyError(callback);

                return;
            }

            platformData = await this.createPlatformData(event);

            this.fileOperationsManager.proxy.EmptyTrashRemote(
                askConfirmation,
                platformData.data,
                (source, error) => {
                    platformData.freePlatformData();
                    if (callback)
                        callback(source, error);

                    if (error) {
                        console.log(
                            'Error trashing files on the desktop: ' +
                            `${error.message}`
                        );
                    }
                }
            );
        } catch (e) {
            platformData?.freePlatformData();
            console.error(e);
        }
    }

    async UndoRemote(event = null, callback = null) {
        let platformData;
        try {
            if (!this.fileOperationsManager.proxy) {
                this._sendNoProxyError(callback);

                return;
            }

            platformData = await this.createPlatformData(event);
            this.fileOperationsManager.proxy.UndoRemote(
                platformData.data,
                (result, error) => {
                    platformData.freePlatformData();
                    if (callback)
                        callback(result, error);

                    if (error)
                        console.log(`Error performing undo: ${error.message}`);
                }
            );
        } catch (e) {
            platformData?.freePlatformData();
            console.error(e);
        }
    }

    async RedoRemote(event = null, callback = null) {
        let platformData;
        try {
            if (!this.fileOperationsManager.proxy) {
                this._sendNoProxyError(callback);

                return;
            }

            platformData = await this.createPlatformData(event);

            this.fileOperationsManager.proxy.RedoRemote(
                platformData.data,
                (result, error) => {
                    platformData.freePlatformData();
                    if (callback)
                        callback(result, error);

                    if (error)
                        console.log(`Error performing redo: ${error.message}`);
                }
            );
        } catch (e) {
            platformData?.freePlatformData();
            console.error(e);
        }
    }

    UndoStatus() {
        return this.fileOperationsManager.proxy.UndoStatus;
    }
}


// eslint-disable-next-line no-unused-vars
const DBusUtils = class {
    constructor(mainApp) {
        this.mainApp = mainApp;
        this.discreteGpuAvailable = false;
        this.dbusManagerObject = new DBusManager(mainApp);
        this._screenSaverActiveChangedSignalId = 0;
        const makeAsync = true;
        const insSytembus = true;
        const insSessionBus = !insSytembus;

        this.NautilusFileOperations2 = new ProxyManager(
            this.dbusManagerObject,
            'org.gnome.Nautilus',
            '/org/gnome/Nautilus/FileOperations2',
            'org.gnome.Nautilus.FileOperations2',
            insSessionBus,
            'Nautilus',
            makeAsync
        );

        this.FreeDesktopFileManager = new ProxyManager(
            this.dbusManagerObject,
            'org.freedesktop.FileManager1',
            '/org/freedesktop/FileManager1',
            'org.freedesktop.FileManager1',
            insSessionBus,
            'Nautilus',
            makeAsync
        );

        this.GnomeNautilusPreview = new ProxyManager(
            this.dbusManagerObject,
            'org.gnome.NautilusPreviewer',
            '/org/gnome/NautilusPreviewer',
            'org.gnome.NautilusPreviewer2',
            insSessionBus,
            'Nautilus-Sushi',
            makeAsync
        );

        this.GnomeArchiveManager = new ProxyManager(
            this.dbusManagerObject,
            'org.gnome.ArchiveManager1',
            '/org/gnome/ArchiveManager1',
            'org.gnome.ArchiveManager1',
            insSessionBus,
            'File-roller',
            makeAsync
        );

        this.GtkVfsMetadata = new ProxyManager(
            this.dbusManagerObject,
            'org.gtk.vfs.Metadata',
            '/org/gtk/vfs/metadata',
            'org.gtk.vfs.Metadata',
            insSessionBus,
            'Gvfs daemon',
            makeAsync
        );

        this.SwitcherooControl = new ProxyManager(
            this.dbusManagerObject,
            'net.hadess.SwitcherooControl',
            '/net/hadess/SwitcherooControl',
            'net.hadess.SwitcherooControl',
            insSytembus,
            'Switcheroo control',
            makeAsync
        );
        this.discreteGpuAvailable = this.SwitcherooControl.isAvailable;
        this.SwitcherooControl.connect('changed-status', (obj, newStatus) => {
            this.discreteGpuAvailable = newStatus;
        });

        this.RemoteFileOperations = new RemoteFileOperationsManager(
            this.NautilusFileOperations2,
            this.FreeDesktopFileManager,
            this.GnomeNautilusPreview,
            this.GnomeArchiveManager,
            this.mainApp
        );

        this.GsConnectManager = new ProxyManager(
            this.dbusManagerObject,
            'org.gnome.Shell.Extensions.GSConnect',
            '/org/gnome/Shell/Extensions/GSConnect',
            'org.freedesktop.DBus.ObjectManager',
            insSessionBus,
            'GsConnect Extension',
            makeAsync
        );

        this.RemoteSendFileOperations =
            new GsConnect.GsConnectSendFileOperationsManager(
                this.GsConnectManager,
                this.mainApp
            );

        const appID = this.mainApp.get_application_id().replace(/test$/, '');
        const extBusID = `${appID}extension`;
        const extBusPath = GLib.build_filenamev(['/', ...extBusID.split('.')]);
        const extBusInterface = extBusID;

        this.RemoteExtensionManager = new ProxyManager(
            this.dbusManagerObject,
            extBusID,
            extBusPath,
            extBusInterface,
            insSessionBus,
            null,
            makeAsync
        );

        this.RemoteExtensionControl =
            new ExtensionControl(this.RemoteExtensionManager);

        this._connectScreenSaverActiveChangedSignal();
    }

    _connectScreenSaverActiveChangedSignal() {
        try {
            this._screenSaverActiveChangedSignalId =
                Gio.DBus.session.signal_subscribe(
                    'org.gnome.ScreenSaver',
                    'org.gnome.ScreenSaver',
                    'ActiveChanged',
                    '/org/gnome/ScreenSaver',
                    null,
                    Gio.DBusSignalFlags.NONE,
                    (_connection, _sender, _objectPath, _iface, _signal, params) => {
                        const [active] = params.deepUnpack();
                        this.emit('screen-saver-active-changed', !!active);
                    }
                );
        } catch (e) {
            console.error(
                'DBusUtils: failed to subscribe to ScreenSaver ActiveChanged:',
                e
            );
        }
    }
};
Signals.addSignalMethods(DBusUtils.prototype);

class ExtensionControl {
    constructor(RemoteExtensionManager) {
        this.RemoteExtensionManager = RemoteExtensionManager;
    }

    async getState() {
        const x = await this._getShellDevicePointer();
        return x ? x[0].slice(2) : null;
    }

    updateDesktopGeometry() {
        this.RemoteExtensionManager.proxy.updateDesktopGeometrySync();
    }

    showShellBackgroundMenu() {
        this.RemoteExtensionManager.proxy.showShellBackgroundMenuSync();
    }

    setWidgetLayerRaised(raised) {
        this.RemoteExtensionManager.proxy.setWidgetLayerRaisedSync(!!raised);
    }

    async getDropTargetCoordinates() {
        const x = await this._getShellDevicePointer();
        return x ? x[0].slice(0, 2) : null;
    }

    _getShellDevicePointer() {
        return new Promise(resolve => {
            try {
                this.RemoteExtensionManager.proxy
                .getShellGlobalCoordinatesRemote(
                    (coords, error) => {
                        if (error) {
                            console.error(error,
                                'Unable to get global Coordinates'
                            );

                            resolve(null);
                        } else {
                            resolve(coords);
                        }
                    }
                );
            } catch (e) {
                console.error(e);
            }
        });
    }

    getDropTargetAppInfoDesktopFile(dropCoordinates = [0, 0]) {
        return new Promise(resolve => {
            try {
                let dropX = dropCoordinates[0];
                let dropY = dropCoordinates[1];

                this.RemoteExtensionManager.proxy
                .getDropTargetAppInfoDesktopFileRemote(
                    [dropX, dropY],
                    (desktopFileAppPath, error) => {
                        if (error) {
                            console.error(error, 'Unable to get .desktop file');

                            resolve(null);
                        // eslint-disable-next-line eqeqeq
                        } else if (desktopFileAppPath == 'null') {
                            resolve(null);
                        } else {
                            resolve(desktopFileAppPath[0]);
                        }
                    }
                );
            } catch (e) {
                console.error(e);
            }
        });
    }

    setDragCursor(cursor = 'default') {
        this.RemoteExtensionManager.proxy.setDragCursorRemote(
            cursor,
            (result, error) => {
                if (error)
                    console.error(error, 'Unable to set Shell Cursor');
            }
        );
    }

    get isAvailable() {
        return this.RemoteExtensionManager.isAvailable;
    }
}
