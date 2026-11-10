// Zuboklik API example: create a patient, find a free slot, book a preventive check-up, move it, clean up.
// Runs on plain Node.js 18+, no packages.  Usage:  ZUBOKLIK_API_KEY=... node booking.mjs

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
async function api(method, path, body) {
  const response = await fetch(API_URL + path, {
    method,
    headers: { Authorization: `Bearer ${API_KEY}`, Accept: 'application/json', 'Content-Type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await response.text();
  const parsed = text ? JSON.parse(text) : null;
  if (!response.ok) throw new ApiError(response.status, parsed?.errors ?? []);
  return parsed;
}

const findByCode = (items, code) => {
  const found = items.find((item) => item.code === code);
  if (!found) throw new Error(`code ${code} not found`);
  return found;
};

// "2026-11-24 09:00-09:30" from anything that has booked_for, start_time and end_time.
const slot = (item) => `${item.booked_for} ${item.start_time.slice(11, 16)}-${item.end_time.slice(11, 16)}`;

const times = ({ booked_for, start_time, end_time }) => ({ booked_for, start_time, end_time });

// Local calendar date `days` from today as YYYY-MM-DD.
function dateInDays(days) {
  const day = new Date();
  day.setDate(day.getDate() + days);
  return `${day.getFullYear()}-${String(day.getMonth() + 1).padStart(2, '0')}-${String(day.getDate()).padStart(2, '0')}`;
}

// 1. Check the connection and the key.
console.log(`1. API is up (${(await api('GET', '')).version})`);

// 2. Catalogs: an appointment needs a symptom, an entry type and an entry state.
const symptom = findByCode((await api('GET', '/symptoms')).symptoms, 'without_complications');
const type = findByCode((await api('GET', '/entry_types')).entry_types, 'prevention');
const state = findByCode((await api('GET', '/entry_states')).entry_states, 'reserved');
console.log(`2. Catalogs loaded: symptom ${symptom.code}, type ${type.code}, state ${state.code}`);

// 3. Create a patient.
const { patient } = await api('POST', '/patients', {
  patient: { first_name: 'Jan', last_name: 'Ukázkový', phone_number: '+420777111222', email: 'jan.ukazkovy@example.com' },
});
console.log(`3. Patient created: ${patient.first_name} ${patient.last_name}`);

// 4. Ask for free 30-minute slots in the next 30 days.
const { vacancies } = await api('GET', `/vacancies?from=${dateInDays(1)}&to=${dateInDays(31)}&duration=30`);
if (vacancies.length < 2) throw new Error('the practice has fewer than two free slots in the next 30 days');
const [first, second] = vacancies;
console.log(`4. Free slots found: ${slot(first)} and ${slot(second)}`);

// 5. Book the first one.
let { entry } = await api('POST', '/entries', {
  entry: {
    entry_type_id: type.id,
    entry_state_id: state.id,
    ...times(first),
    note: 'Booked by the API example',
    patient_symptoms_attributes: [{ patient_id: patient.id, symptom_id: symptom.id }],
  },
});
console.log(`5. Appointment booked: ${slot(entry)}`);

// 6. Move it to the second one.
({ entry } = await api('PATCH', `/entries/${entry.id}`, { entry: times(second) }));
console.log(`6. Appointment moved: ${slot(entry)}`);

// 7. Errors: a patient without a last name is refused with 422 and a list of reasons.
try {
  await api('POST', '/patients', { patient: { first_name: 'Jan' } });
  throw new Error('the API accepted an invalid patient');
} catch (error) {
  if (!(error instanceof ApiError)) throw error;
  console.log(`7. Invalid patient refused: HTTP ${error.status}, attribute ${error.errors[0].attribute}`);
}

// 8. Clean up: delete the appointment, deactivate the patient.
await api('DELETE', `/entries/${entry.id}`);
await api('DELETE', `/patients/${patient.id}`);
console.log('8. Cleaned up');
