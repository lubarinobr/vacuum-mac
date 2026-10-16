// Every call goes through the Windows shell (src-tauri), which talks to the robot service on this PC.
const invoke = (command, args) => window.__TAURI__.core.invoke(command, args);

export const api = (method, path, body) => invoke('api', { method, path, body: body ?? null });
export const tool = (name, args = {}) => api('POST', `/v1/tools/${name}`, args);
export const ensureService = () => invoke('ensure_service');
export const mapImage = (fresh) => invoke('map_image', { fresh });

export function errorText(error) {
  return typeof error === 'string' ? error : error?.message ?? 'Something went wrong.';
}
