# MyFood Backend — Frontend Integration Guide

## Versión: 2026-07-11

**Backend Status:** ✅ Production-ready
**Test Suite:** 498 tests, 0 failures
**Last Updated:** 2026-07-11 (Phase A — Tenancy Refactor / multi-familia, PR 3c)

---

## Tabla de Contenidos

1. [Configuración Base](#configuración-base)
2. [Autenticación](#autenticación)
3. [API REST](#api-rest)
4. [Multi-Familia (Cuentas Múltiples)](#multi-familia-cuentas-múltiples)
5. [WebSocket (Phoenix Channels)](#websocket-phoenix-channels)
6. [Manejo de Errores](#manejo-de-errores)
7. [Tipos de Datos](#tipos-de-datos)
8. [Ejemplos de Código](#ejemplos-de-código)
9. [FAQ](#faq)

---

## Configuración Base

### URLs por Ambiente

| Ambiente | API URL | WebSocket URL |
|----------|---------|--------------|
| **Development** | `http://localhost:4000` | `ws://localhost:4000/socket` |
| **Staging** | `https://api-staging.myfood.com` | `wss://api-staging.myfood.com/socket` |
| **Production** | `https://api.myfood.com` | `wss://api.myfood.com/socket` |

### Headers Requeridos

```javascript
// Para todas las requests
headers: {
  "Content-Type": "application/json",
  "Authorization": "Bearer <jwt_token>"
}
```

### CORS

✅ **Configurado** — El backend acepta requests desde:
- `http://localhost:8081` (React Native dev)
- `exp://*` (Expo)
- `*` (cualquier origen en desarrollo)

---

## Autenticación

### Flujo JWT

1. **Login** → Recibir JWT token
2. **Usar token** → Incluir en header `Authorization: Bearer <token>`
3. **WebSocket** → Pasar token en `params` al conectar
4. **Refresh** → Implementar retry con nuevo token cuando expire

### Login (ejemplo)

```bash
POST /api/auth/login
Content-Type: application/json

{
  "email": "user@example.com",
  "password": "password123"
}
```

**Response:**
```json
{
  "token": "eyJhbGciOiJIUzI1NiIs...",
  "user": {
    "id": 1,
    "email": "user@example.com",
    "account_id": 1
  }
}
```

### Conectar WebSocket con Token

```javascript
import { Socket } from "phoenix";

const socket = new Socket("/socket", {
  params: { token: "<jwt_token>" }
});

socket.connect();
```

### Token `access_v2` (Phase A — Multi-Familia)

A partir de Phase A ("Tenancy Refactor"), el backend puede emitir dos
tipos de token: el legacy `access` (una sola cuenta implícita) y el
nuevo `access_v2`, que carga explícitamente a qué `AccountMembership`
está ligado el token. Esto es lo que permite el modelo "Spotify
Family": un mismo usuario puede tener membership en varias cuentas
(familias) y elegir cuál está activa sin volver a loguearse — ver
[Multi-Familia](#multi-familia-cuentas-múltiples).

El frontend **no necesita decodificar el JWT** para saber qué cuenta
está activa — el backend siempre responde con `membership` y `account`
serializados en el body (ver ejemplos abajo). Pero para debugging, el
claim shape es:

```json
{
  "sub": "<user_id>",
  "typ": "access_v2",
  "membership_id": "<account_membership_id>",
  "account_id": "<account_id>",
  "role": "owner",
  "plan": "family_4",
  "status": "active",
  "email": "user@example.com",
  "name": "User Name",
  "iat": 1700000000,
  "exp": 1702592000
}
```

Cuál tipo de token emite el backend en cada login/registro/refresh
depende de una feature flag del lado del servidor
(`MEAL_PLANNER_TENANCY_V2`) — el frontend debe tratar ambos tipos de
forma transparente (mismo header `Authorization: Bearer <token>`, mismo
manejo de refresh) y NO asumir un tipo específico.

---

## API REST

### Endpoints Disponibles

| Método | Endpoint | Descripción |
|--------|----------|-------------|
| `POST` | `/api/auth/login` | Login con email/password |
| `POST` | `/api/auth/social` | Login con Google/Apple/Facebook |
| `GET` | `/api/calendar` | Obtener calendario mensual |
| `GET` | `/api/calendar/slot?date=YYYY-MM-DD&slot=breakfast` | Obtener slot específico |
| `POST` | `/api/planning/generate` | Generar plan semanal |
| `POST` | `/api/planning/confirm` | Confirmar propuesta |
| `GET` | `/api/shopping/list` | Lista de compras |
| `POST` | `/api/shopping/checkout` | Confirmar compra |
| `GET` | `/api/recipes` | Lista de recetas |
| `GET` | `/api/inventory` | Inventario del usuario |

### Ejemplo: Obtener Calendario

```bash
GET /api/calendar?month=2026-06
Authorization: Bearer <token>
```

**Response:**
```json
{
  "meals": [
    {
      "id": 123,
      "date": "2026-06-03",
      "slot": "lunch",
      "recipe_id": 45,
      "recipe_name": "Pollo al horno",
      "calories_per_serving": 450,
      "prep_time_minutes": 35,
      "is_favorite": false,
      "is_cooked": false,
      "can_create": false
    }
  ],
  "selected_date": "2026-06-03",
  "selected_meal": {
    "id": 123,
    "date": "2026-06-03",
    "slot": "lunch",
    "recipe_id": 45,
    "recipe_name": "Pollo al horno",
    "can_create": false
  }
}
```

### Ejemplo: Generar Plan

```bash
POST /api/planning/generate
Authorization: Bearer <token>

{
  "date_from": "2026-06-10",
  "date_to": "2026-06-16",
  "constraints": {
    "budget_cents": 15000,
    "protein_g": 30,
    "max_calories": 800
  }
}
```

**Response:**
```json
{
  "proposal_id": 789,
  "request_id": "req_12345",
  "status": "generating"
}
```

---

## Multi-Familia (Cuentas Múltiples)

Phase A ("Tenancy Refactor") agrega el modelo "Spotify Family para meal
plans": un mismo `User` puede tener `AccountMembership` en varias
cuentas ("familias"), con un rol por cuenta (`owner` o `member`). La
cuenta activa la determina el JWT (`membership_id`), y cambiar de cuenta
activa es simplemente pedir un JWT nuevo — no hay "tomar control" ni
"transferir" cuentas entre usuarios.

Todos los endpoints de esta sección requieren `Authorization: Bearer
<token>`, salvo donde se indique lo contrario.

### Tabla de endpoints nuevos

| Método | Endpoint | Descripción | Rol requerido |
|--------|----------|-------------|----------------|
| `POST` | `/api/accounts/:account_id/invites` | Invitar por email | `owner` |
| `POST` | `/api/invites/:token/accept` | Aceptar invitación | — (sin auth) |
| `GET` | `/api/accounts/:account_id/memberships` | Listar miembros | cualquier miembro activo |
| `DELETE` | `/api/accounts/:account_id/memberships/:user_id` | Remover miembro | `owner` |
| `POST` | `/api/auth/switch-account` | Cambiar cuenta activa | cualquiera (dueño de la membership) |
| `POST` | `/api/accounts/:account_id/leave` | Abandonar la cuenta | `member` (el `owner` no puede) |

### 1. Invitar a un miembro

```bash
POST /api/accounts/:account_id/invites
Authorization: Bearer <owner_token>
Content-Type: application/json

{ "email": "ana@example.com" }
```

**Response `201`:**
```json
{
  "invite": {
    "token": "8f3d9e2a...43-char-plaintext-token",
    "expires_at": "2026-07-18T12:00:00Z",
    "membership_id": "3b9d2f4a-...",
    "email": "ana@example.com"
  }
}
```

El `token` plaintext se muestra **una sola vez** — el backend solo
guarda su hash. El frontend debe compartirlo con el invitado (deep
link, copiar/compartir, etc.) inmediatamente después de recibirlo.

**Errores:**

| Status | `error` | Causa | Acción recomendada |
|--------|---------|-------|---------------------|
| `403` | `not_owner` | El caller no es `owner` de la cuenta | Ocultar la opción de invitar para `member` |
| `409` | `seat_cap_reached` | La cuenta llegó al límite de su plan | Mostrar upsell / cambio de plan |
| `409` | `already_invited` | Ya hay una invitación `:invited` pendiente para ese email | Mostrar "ya invitado", ofrecer reenviar |

### 2. Aceptar una invitación

**Deliberadamente NO requiere `Authorization`** — el caso "usuario
nuevo" no tiene cuenta/token todavía. Dos variantes según si el
invitado ya tiene cuenta en MyFood o no:

**Usuario existente** (opcionalmente manda su `Authorization` header
actual para que el backend identifique quién acepta):
```bash
POST /api/invites/:token/accept
Authorization: Bearer <existing_user_token>   # opcional pero recomendado
Content-Type: application/json

{}
```

**Usuario nuevo:**
```bash
POST /api/invites/:token/accept
Content-Type: application/json

{ "name": "Ana Pérez", "password": "supersecret123" }
```

**Response `200`** — mismo shape que login/registro (ver
[Login](#login-ejemplo)), con la membership recién aceptada:
```json
{
  "access_token": "eyJ...",
  "refresh_token": "eyJ...",
  "token_type": "Bearer",
  "user": { "id": "...", "email": "ana@example.com", "name": "Ana Pérez" },
  "account": { "id": "...", "name": "Familia Pérez", "plan": "family_4" },
  "membership": {
    "id": "3b9d2f4a-...",
    "account_id": "...",
    "role": "member",
    "status": "active",
    "joined_at": "2026-07-11T18:22:00Z"
  },
  "subscription": { "max_users": 4, "max_planning_days": 5 },
  "websocket": { "path": "/socket/websocket", "params": { "token": "eyJ..." } }
}
```

Guardar `access_token`/`refresh_token` exactamente igual que en el
flujo de login normal — a partir de acá el usuario ya está autenticado
y puede usar el resto de la API con esta nueva cuenta activa.

**Errores:**

| Status | `error` | Causa | Acción recomendada |
|--------|---------|-------|---------------------|
| `401` | `unauthorized` | Body vacío `{}` sin `Authorization` válido (caso "usuario existente" mal armado) | Pedir login o completar `name`/`password` |
| `410` | `invite_token_used` | El token ya fue usado antes | Mostrar "invitación ya usada", pedir una nueva |
| `410` | `invite_token_expired` | Pasaron más de 7 días desde la invitación | Pedir al `owner` que reenvíe |
| `404` | `invite_token_unknown` | Token inválido/no existe | Mostrar "invitación inválida" |
| `409` | `already_a_member` | Carrera: dos aceptaciones simultáneas del mismo invite | Tratar como éxito silencioso (reintentar login) |

### 3. Listar miembros de una cuenta

```bash
GET /api/accounts/:account_id/memberships
Authorization: Bearer <token>
```

**Response `200`:**
```json
{
  "memberships": [
    {
      "user_id": "...",
      "email": "owner@example.com",
      "name": "Owner Name",
      "role": "owner",
      "status": "active",
      "joined_at": "2026-06-01T10:00:00Z"
    },
    {
      "user_id": "...",
      "email": "ana@example.com",
      "name": "Ana Pérez",
      "role": "member",
      "status": "active",
      "joined_at": "2026-07-11T18:22:00Z"
    }
  ]
}
```

Ordenado `owner` primero, luego por fecha de ingreso. Incluye filas
`:invited` (todavía no aceptadas) para que la UI pueda mostrar
"invitación pendiente".

**Errores:** `404 account_not_found` (no-miembros reciben 404, no 403 —
no hay leak de existencia de la cuenta); `403 account_mismatch` si el
`:account_id` de la URL no coincide con la cuenta activa del token (ver
[Manejo de Errores](#manejo-de-errores)).

### 4. Remover un miembro (solo `owner`)

```bash
DELETE /api/accounts/:account_id/memberships/:user_id
Authorization: Bearer <owner_token>
```

**Response:** `204 No Content`.

**Errores:** `403 not_owner`, `403 cannot_remove_owner` (el `owner` no
puede auto-removerse por esta vía), `404 membership_not_found`.

### 5. Cambiar de cuenta activa (switch-account)

```bash
POST /api/auth/switch-account
Authorization: Bearer <token>
Content-Type: application/json

{ "membership_id": "<other_account_membership_id>" }
```

**Response `200`** — mismo shape completo que "Aceptar invitación"
arriba (`access_token`, `refresh_token`, `user`, `account`, `membership`,
`subscription`, `websocket`), pero ahora escoged a la OTRA cuenta.

```javascript
async function switchAccount(membershipId) {
  const token = await AsyncStorage.getItem("auth_token");
  const response = await fetch("http://localhost:4000/api/auth/switch-account", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "Authorization": `Bearer ${token}`
    },
    body: JSON.stringify({ membership_id: membershipId })
  });

  const data = await response.json();
  if (!response.ok) throw new Error(data.error);

  // Reemplazar el token guardado — TODAS las requests/sockets
  // subsiguientes deben usar este nuevo token.
  await AsyncStorage.setItem("auth_token", data.access_token);
  await AsyncStorage.setItem("account", JSON.stringify(data.account));
  return data;
}
```

**Importante:** después de un switch exitoso, cualquier WebSocket ya
conectado con el token viejo sigue funcionando para la cuenta vieja,
pero para operar sobre la cuenta nueva hay que **reconectar el socket
con el nuevo token** (ver
["Patrón de dos sockets"](#patrón-de-dos-sockets-multi-familia) abajo).

**Errores:**

| Status | `error` | Causa | Acción recomendada |
|--------|---------|-------|---------------------|
| `403` | `not_your_membership` | El `membership_id` pertenece a otro usuario | No debería pasar desde la UI normal — bug de cliente |
| `409` | `membership_not_active` | La membership está `:suspended` (no `:invited`/`:active`) | Mostrar "acceso suspendido a esta cuenta" |
| `404` | `membership_not_found` | El `membership_id` no existe | No debería pasar desde la UI normal |

### 6. Abandonar una cuenta (solo `member`, no `owner`)

```bash
POST /api/accounts/:account_id/leave
Authorization: Bearer <token>
```

**Response:** `204 No Content`. El usuario pierde acceso inmediato a
esa cuenta — si tenía otras membership activas, debe hacer
switch-account a alguna de ellas.

**Errores:** `403 cannot_leave_owned_account` (el `owner` debe primero
transferir ownership o eliminar la cuenta — no soportado todavía),
`404 not_a_member`.

---

## WebSocket (Phoenix Channels)

### Canales Disponibles

| Canal | Tópico | Propósito |
|-------|--------|----------|
| `ai_chat` | `ai_chat:<session_id>` | Asistente AI de meal planning |
| `calendar` | `calendar:<account_id>` | Operaciones de calendario en tiempo real |
| `planning` | `planning:<account_id>` | Generación de planes y confirmación |
| `cooking` | `cooking:<recipe_id>` | Modo cooking con timers y guía |

### Canal de Planificación (para generar menús)

```javascript
// 1. Conectar al canal de planificación
const planningChannel = socket.channel("planning:1", {});

// 2. Unirse al canal
planningChannel.join()
  .receive("ok", resp => console.log("Joined!", resp))
  .receive("error", resp => console.log("Unable to join", resp));

// 3. Escuchar eventos de generación
planningChannel.on("generation_started", payload => {
  console.log("Generando menú...", payload);
});

planningChannel.on("proposal_ready", payload => {
  console.log("Propuesta lista!", payload);
  // payload.proposal_id para confirmar/rechazar
});

// 4. Generar menú
planningChannel.push("generate_menu", {
  date_from: "2026-06-10",
  date_to: "2026-06-16",
  constraints: { budget_cents: 15000, protein_g: 30 }
});
```

### Canal de Calendario

```javascript
// 1. Conectar al canal de calendario
const calendarChannel = socket.channel("calendar:1", {});

// 2. Unirse
calendarChannel.join();

// 3. Escuchar cambios
calendarChannel.on("meal_updated", payload => {
  console.log("Meal actualizado:", payload);
  // Actualizar UI
});

// 4. Marcar comida como cocinada
calendarChannel.push("set_is_cooked", {
  meal_id: 123,
  is_cooked: true
})
  .receive("ok", resp => console.log("Marcado!"))
  .receive("error", resp => console.log("Error:", resp));

// 5. Toggle favorito
calendarChannel.push("toggle_favorite", {
  recipe_id: "45"
})
  .receive("ok", resp => console.log("Favorito toggled!", resp));
```

### Canal de Cooking

```javascript
// 1. Conectar
const cookingChannel = socket.channel("cooking:123", {});

// 2. Iniciar sesión de cooking
cookingChannel.push("start_session", {
  scheduled_meal_id: "789"
});

// 3. Escuchar eventos
cookingChannel.on("session_started", payload => {
  console.log("Cooking started!", payload);
});

cookingChannel.on("step_tracked", payload => {
  console.log("Step completado:", payload);
});

cookingChannel.on("timer_done", payload => {
  // Notificar al usuario
  showNotification(`Timer: ${payload.label}`);
});

// 4. Tracking de pasos
cookingChannel.push("track_step", {
  session_id: payload.session_id,
  recipe_step_id: 3,
  status: "completed"
});
```

### Patrón de dos sockets (multi-familia)

Cada canal de datos (`calendar:<account_id>`, `planning:<account_id>`,
etc.) valida en el `join` que el token conectado tenga
`current_membership.account_id` igual al `<account_id>` del tópico —
igual que las rutas REST. Un usuario multi-familia que necesita ver
actualizaciones en tiempo real de **dos cuentas simultáneamente** (por
ejemplo, un dashboard que muestra ambas familias) necesita **dos
sockets separados, cada uno conectado con el token de la cuenta
correspondiente** — un solo socket/token solo puede unirse a tópicos de
la cuenta a la que ese token está scoped.

```javascript
import { Socket } from "phoenix";

// Socket 1 — token scoped a Account A
const tokenA = await getTokenForMembership(membershipIdA); // switch-account si hace falta
const socketA = new Socket("/socket", { params: { token: tokenA } });
socketA.connect();
const calendarA = socketA.channel(`calendar:${accountIdA}`, {});
calendarA.join().receive("ok", () => console.log("Joined Account A calendar"));

// Socket 2 — token scoped a Account B (independiente del anterior)
const tokenB = await getTokenForMembership(membershipIdB);
const socketB = new Socket("/socket", { params: { token: tokenB } });
socketB.connect();
const calendarB = socketB.channel(`calendar:${accountIdB}`, {});
calendarB.join().receive("ok", () => console.log("Joined Account B calendar"));

// Cada socket solo recibe broadcasts de SU propia cuenta — un evento
// en calendar:<accountIdA> nunca llega a calendarB, y viceversa.
calendarA.on("meal_updated", payload => updateAccountAUI(payload));
calendarB.on("meal_updated", payload => updateAccountBUI(payload));
```

Para el caso normal (una sola cuenta activa a la vez, con
switch-account entre ellas) **no hace falta** este patrón — basta con
reconectar el socket existente con el nuevo token después de un
`switch-account` exitoso (ver
[Cambiar de cuenta activa](#5-cambiar-de-cuenta-activa-switch-account)).

Intentar unirse a `calendar:<account_id>` de una cuenta a la que el
token conectado NO pertenece devuelve `{error: {reason: "forbidden"}}`
en el `receive("error", ...)` del `join` — igual que el `403
account_mismatch` de las rutas REST con `:account_id` en la URL.

---

## Manejo de Errores

### Formato de Error (consistente en toda la API)

```json
{
  "error": "not_found"
}
```

O para errores de validación:

```json
{
  "errors": {
    "detail": "Not Found"
  }
}
```

### Códigos de Error Comunes

| Código | Significado | Acción Recomendada |
|--------|-------------|-------------------|
| `unauthenticated` | Token inválido o expirado | Refrescar token o re-login |
| `forbidden` | No tiene permisos | Verificar account_id |
| `account_mismatch` | El `:account_id` de la URL no coincide con la cuenta activa del token (multi-familia) | Hacer `switch-account` a la cuenta correcta primero, ver [Multi-Familia](#multi-familia-cuentas-múltiples) |
| `not_found` | Recurso no existe | Verificar IDs |
| `invalid_payload` | Datos inválidos | Validar input del usuario |
| `generation_in_progress` | Ya hay una generación en curso | Esperar o cancelar |
| `no_active_generation` | No hay generación activa | Generar primero |
| `budget_exceeded` | Supera el presupuesto | Reducir constraints |
| `unreachable` | Servicio externo no disponible | Retry con backoff |

### Reconnection Strategy (ejemplo completo)

```javascript
class MyFoodSocket {
  constructor(baseUrl, token) {
    this.baseUrl = baseUrl;
    this.token = token;
    this.maxReconnectAttempts = 10;
    this.reconnectAttempts = 0;
  }

  connect() {
    this.socket = new Socket(`${this.baseUrl}/socket`, {
      params: { token: this.token }
    });

    this.socket.onError(() => this.handleError());
    this.socket.onClose(() => this.handleClose());

    this.socket.connect();
  }

  handleError() {
    console.error("Socket connection error");
    // Notificar al usuario
    showErrorNotification("Conexión perdida. Reconectando...");
  }

  handleClose() {
    if (this.reconnectAttempts < this.maxReconnectAttempts) {
      const delay = this.calculateBackoff();
      console.log(`Reconnecting in ${delay}ms...`);

      setTimeout(() => {
        this.reconnectAttempts++;
        this.refreshToken().then(newToken => {
          this.token = newToken;
          this.connect();
        });
      }, delay);
    } else {
      showErrorNotification("No se pudo reconectar. Por favor re-login.");
    }
  }

  calculateBackoff() {
    const base = 1000;
    const maxDelay = 30000;
    const exponentialDelay = Math.min(
      base * Math.pow(2, this.reconnectAttempts),
      maxDelay
    );
    const jitter = Math.random() * 1000;
    return exponentialDelay + jitter;
  }

  async refreshToken() {
    // Llamar al endpoint de refresh
    const response = await fetch(`${this.baseUrl}/api/auth/refresh`, {
      method: "POST",
      credentials: "include"
    });
    const { token } = await response.json();
    return token;
  }
}
```

---

## Tipos de Datos

### Dates

Formato ISO 8601: `YYYY-MM-DD`

```javascript
// Ejemplo
const date = "2026-06-10";
```

### Slots

Valores posibles: `breakfast`, `lunch`, `snack`, `dinner`

```javascript
const SLOT_TYPES = ["breakfast", "lunch", "snack", "dinner"];
```

### Monedas

Siempre en **centavos** (enteros).

```javascript
// 15.00 USD = 1500 cents
const budgetCents = 1500;
```

### Macros de Recetas

```javascript
const macros = {
  protein_g: 25,      // gramos de proteína
  calories: 450,       // calorías
  carbs_g: 30         // gramos de carbohidratos
};
```

---

## Ejemplos de Código

### Login + Guardar Token

```javascript
async function login(email, password) {
  const response = await fetch("http://localhost:4000/api/auth/login", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ email, password })
  });

  if (!response.ok) {
    const error = await response.json();
    throw new Error(error.error || "Login failed");
  }

  const { token, user } = await response.json();

  // Guardar token (ejemplo con AsyncStorage)
  await AsyncStorage.setItem("auth_token", token);
  await AsyncStorage.setItem("user", JSON.stringify(user));

  return { token, user };
}
```

### Obtener Calendario

```javascript
async function getCalendar(month) {
  const token = await AsyncStorage.getItem("auth_token");

  const response = await fetch(
    `http://localhost:4000/api/calendar?month=${month}`,
    {
      headers: { "Authorization": `Bearer ${token}` }
    }
  );

  return response.json();
}
```

### Generar Plan Semanal (con WebSocket)

```javascript
class PlanningService {
  constructor(socket) {
    this.channel = socket.channel("planning:1", {});
    this.listeners = {};
  }

  async generate(dateFrom, dateTo, constraints) {
    return new Promise((resolve, reject) => {
      // Escuchar respuesta
      this.channel.on("proposal_ready", payload => {
        resolve(payload);
      });

      this.channel.on("generation_error", payload => {
        reject(new Error(payload.reason));
      });

      // Unirse y generar
      this.channel.join().receive("ok", () => {
        this.channel.push("generate_menu", {
          date_from: dateFrom,
          date_to: dateTo,
          constraints
        });
      });
    });
  }

  async confirm(proposalId) {
    return new Promise((resolve, reject) => {
      this.channel.on("proposal_confirmed", payload => {
        resolve(payload);
      });

      this.channel.push("confirm_proposal", { proposal_id: proposalId });
    });
  }
}
```

### Uso en React Native

```javascript
import React, { useEffect, useState } from "react";
import { Socket } from "phoenix";

function App() {
  const [socket, setSocket] = useState(null);
  const [planning, setPlanning] = useState(null);

  useEffect(() => {
    const initSocket = async () => {
      const token = await AsyncStorage.getItem("auth_token");
      const s = new Socket("ws://localhost:4000/socket", {
        params: { token }
      });
      s.connect();
      setSocket(s);
    };

    initSocket();
  }, []);

  const handleGenerate = async () => {
    const service = new PlanningService(socket);
    const result = await service.generate(
      "2026-06-10",
      "2026-06-16",
      { budget_cents: 15000, protein_g: 30 }
    );
    setPlanning(result);
  };

  return (
    <View>
      <Button title="Generar Plan" onPress={handleGenerate} />
    </View>
  );
}
```

---

## FAQ

### ¿El backend soporta offline?

El backend no maneja cache offline directamente. Se recomienda:
- Usar AsyncStorage para cache local
- Implementar SyncManager para reconectar y sincronizar
- Guardar operaciones pendientes y reintentarlas cuando haya conexión

### ¿Cómo manejo tokens expirados?

1.捕获 error `unauthenticated`
2. Llamar endpoint de refresh o re-login
3. Reconectar socket con nuevo token
4. Reintentar operación

### ¿Qué pasa si el optimizador no encuentra solución?

El backend devuelve `no_valid_plan`. Opciones:
- Relajar constraints (menos proteína, más presupuesto)
- Excluir ingredientes problemáticos
- Reducir días de planificación

### ¿Puedo usar el mismo WebSocket para múltiples canales?

Sí, un solo socket puede conectarse a múltiples canales:

```javascript
const socket = new Socket("/socket", { params: { token } });
socket.connect();

const calendarChannel = socket.channel("calendar:1", {});
const planningChannel = socket.channel("planning:1", {});
const aiChannel = socket.channel("ai_chat:session123", {});
```

### ¿Los canales se desconectan solos?

Phoenix Channels manejan heartbeats automáticamente. Si hay desconexión:
1. El evento `onClose` se dispara
2. Implementar reconnection con exponential backoff (ver ejemplo arriba)
3. Resubscribe a los canales necesarios

---

## Checklist de Integración

- [ ] Configurar URL base del backend
- [ ] Implementar login con JWT
- [ ] Guardar token en storage seguro
- [ ] Incluir Authorization header en todas las requests
- [ ] Conectar WebSocket con token
- [ ] Implementar reconnection strategy
- [ ] Manejar errores según tabla de códigos
- [ ] Probar flow completo: login → calendario → generar plan → confirmar

---

## Contacto

Para dudas técnicas, contactar al equipo de backend:
- **Email:** backend@myfood.com
- **Slack:** #team-backend

**Versión del API:** 2026-07-11
**Última actualización:** 2026-07-11