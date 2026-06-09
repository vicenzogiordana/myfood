# MyFood Backend — Frontend Integration Guide

## Versión: 2026-06-09

**Backend Status:** ✅ Production-ready
**Test Suite:** 272 tests, 0 failures
**Last Updated:** 2026-06-09

---

## Tabla de Contenidos

1. [Configuración Base](#configuración-base)
2. [Autenticación](#autenticación)
3. [API REST](#api-rest)
4. [WebSocket (Phoenix Channels)](#websocket-phoenix-channels)
5. [Manejo de Errores](#manejo-de-errores)
6. [Tipos de Datos](#tipos-de-datos)
7. [Ejemplos de Código](#ejemplos-de-código)
8. [FAQ](#faq)

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

**Versión del API:** 2026-06-09
**Última actualización:** 2026-06-09