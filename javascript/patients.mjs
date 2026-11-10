// Zuboklik API example: create patients, page through the list, read, update and deactivate one, see 404 and 401.
// Runs on plain Node.js 18+, no packages.  Usage:  ZUBOKLIK_API_KEY=... node patients.mjs

const API_URL = process.env.ZUBOKLIK_API_URL ?? 'https://zuboklik.cz/api/v1';
const API_KEY = process.env.ZUBOKLIK_API_KEY;
if (!API_KEY) throw new Error('set ZUBOKLIK_API_KEY');

// Thrown for every non-2xx answer. `errors` is the parsed "errors" array of the response.
class ApiError extends Error {
  constructor(status, errors) {
    super(`HTTP ${status}: ${JSON.stringify(errors)}`);
    this.status = status;
    this.errors = errors;
  }
}

// One request. Returns the parsed JSON body (null for 204 No Content).
async function api(method, path, body, key = API_KEY) {
  const response = await fetch(API_URL + path, {
    method,
    headers: { Authorization: `Bearer ${key}`, Accept: 'application/json', 'Content-Type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await response.text();
  const parsed = text ? JSON.parse(text) : null;
  if (!response.ok) throw new ApiError(response.status, parsed?.errors ?? []);
  return parsed;
}

// 1. Create two patients.
const { patient: jana } = await api('POST', '/patients', { patient: { first_name: 'Jana', last_name: 'Ukázková', phone_number: '+420777111222' } });
const { patient: petr } = await api('POST', '/patients', { patient: { first_name: 'Petr', last_name: 'Ukázkový', email: 'petr.ukazkovy@example.com' } });
console.log(`1. Patients created: ${jana.first_name} ${jana.last_name} and ${petr.first_name} ${petr.last_name}`);

// 2. Page through the whole list, 100 patients per request (the maximum). `meta` says how many pages there are.
const patients = [];
let page = 1;
for (;;) {
  const list = await api('GET', `/patients?page=${page}&per_page=100`);
  patients.push(...list.patients);
  if (page >= list.meta.total_pages) break;
  page += 1;
}
const ours = patients.filter((patient) => [jana.id, petr.id].includes(patient.id)).length;
console.log(`2. Patients listed: ${patients.length} on ${page} page(s), ours among them: ${ours}`);

// 3. Read one patient.
const { patient: detail } = await api('GET', `/patients/${jana.id}`);
console.log(`3. Patient read: ${detail.first_name} ${detail.last_name}`);

// 4. Update: only the attributes you send change.
const { patient: updated } = await api('PATCH', `/patients/${jana.id}`, { patient: { email: 'jana.ukazkova@example.com' } });
console.log(`4. Patient updated: ${updated.email}, still ${updated.last_name}`);

// 5. Deactivate both. The record stays in the practice's card index, the API no longer returns it.
await api('DELETE', `/patients/${jana.id}`);
await api('DELETE', `/patients/${petr.id}`);
console.log('5. Patients deactivated');

// 6. A deactivated (or unknown) patient answers 404.
try {
  await api('GET', `/patients/${jana.id}`);
  throw new Error('the API still returns a deactivated patient');
} catch (error) {
  if (!(error instanceof ApiError)) throw error;
  console.log(`6. Deactivated patient not found: HTTP ${error.status}, ${error.errors[0].name}`);
}

// 7. A wrong key answers 401.
try {
  await api('GET', '/patients', undefined, 'not-a-valid-key');
  throw new Error('the API accepted a wrong key');
} catch (error) {
  if (!(error instanceof ApiError)) throw error;
  console.log(`7. Wrong key refused: HTTP ${error.status}, ${error.errors[0].name}`);
}
