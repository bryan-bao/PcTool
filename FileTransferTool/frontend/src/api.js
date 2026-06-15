// Wails 把 Go 的 App 方法暴露在 window.go.main.App
export const App = () => window.go.main.App;

export async function mobileQR() { return App().MobileQR(); }
export async function mobileURL() { return App().MobileURL(); }
export async function saveDir() { return App().SaveDir(); }
export async function tasks() { return App().Tasks(); }
export function setGlobalLimit(bps) { return App().SetGlobalLimit(bps); }
export function setTaskLimit(id, bps) { return App().SetTaskLimit(id, bps); }
export function accept(id) { return App().Accept(id); }
export function reject(id) { return App().Reject(id); }
export function discoverPeers() { return App().DiscoverPeers(); }
export function pickFiles() { return App().PickFiles(); }
export function pickFolder() { return App().PickFolder(); }
export function openSaveDir() { return App().OpenSaveDir(); }
export function sendToPeer(host, port, paths) { return App().SendToPeer(host, port, paths); }
export function pickSaveDir() { return App().PickSaveDir(); }
export function copyURL() { return App().CopyURL(); }
export function localAddr() { return App().LocalAddr(); }
export function installTailscale() { return App().InstallTailscale(); }
export function shareState() { return App().ShareState(); }
export function shareAddFiles() { return App().ShareAddFiles(); }
export function shareAddFolder() { return App().ShareAddFolder(); }
export function shareRemove(id) { return App().ShareRemove(id); }
export function copyText(text) { return App().CopyText(text); }
