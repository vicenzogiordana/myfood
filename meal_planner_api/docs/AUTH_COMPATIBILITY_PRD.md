# PRD: Auth Compatibility — Backend para Frontend React Native

**Versión:** 1.0
**Fecha:** 2026-06-11
**Estado:** Draft
**Prioridad:** 🔴 Alta

---

## 1. Problem Statement

El frontend React Native (Expo) fue desarrollado con expectativas específicas para los endpoints de autenticación. El backend Elixir/Phoenix tiene una implementación funcional pero con nombres de endpoints y formatos de response diferentes a lo esperado.

**Impacto:** El equipo de frontend no puede integrar la autenticación hasta que el backend se alinee con sus expectativas.

---

## 2. Scope

### 2.1 In Scope

- Agregar aliases de endpoints para matchear expectativas del frontend
- Implementar endpoint de logout
- Implementar endpoint de refresh token
- Asegurar que `user.id` sea string en todas las responses
- Agregar campo `avatar_url` al schema de User

### 2.2 Out of Scope

- Cambiar la lógica de negocio de autenticación (ya funciona)
- Modificar el flujo de OAuth social (ya funciona)
- Agregar nuevos providers de OAuth

---

## 3. Gaps Identificados

| # | Gap | Severidad | Esfuerzo | Estado |
|---|-----|-----------|----------|--------|
| G1 | Endpoint `POST /auth/login` → `POST /auth/password` | 🔴 Alta | 15 min | ⏳ |
| G2 | Endpoint `POST /auth/register` → `POST /auth/password` | 🔴 Alta | 15 min | ⏳ |
| G3 | Endpoint `POST /auth/google` → `POST /auth/social` | 🔴 Alta | 15 min | ⏳ |
| G4 | Endpoint `POST /auth/facebook` → `POST /auth/social` | 🔴 Alta | 15 min | ⏳ |
| G5 | Endpoint `POST /auth/apple` → `POST /auth/social` | 🔴 Alta | 15 min | ⏳ |
| G6 | `POST /auth/refresh` no existe | 🔴 Alta | 45 min | ⏳ |
| G7 | `POST /auth/logout` no existe | 🔴 Alta | 30 min | ⏳ |
| G8 | `GET /auth/me` → `GET /me` | 🟡 Media | 15 min | ⏳ |
| G9 | `user.id` integer → string | 🟡 Media | 20 min | ⏳ |
| G10 | `user.avatar_url` no existe | 🟡 Media | 30 min | ⏳ |
| G11 | `refresh_token` en response | 🔴 Alta | 45 min | ⏳ |

---

## 4. Solution Design

### 4.1 Route Aliases (G1-G5, G8)

Agregar rutas aliases en el router que apunten a los handlers existentes:

```
POST /auth/login          → AuthController.password (mode: "login")
POST /auth/register       → AuthController.password (mode: "register")
POST /auth/google         → AuthController.social (provider: "google")
POST /auth/facebook       → AuthController.social (provider: "facebook")
POST /auth/apple          → AuthController.social (provider: "apple")
GET  /auth/me             → AccountsController.me
```

**No se requiere código nuevo** — solo agregar rutas aliases en `router.ex`.

### 4.2 Refresh Token (G6, G11)

Implementar flujo de refresh token con Guardian:

**Request:**
```json
POST /auth/refresh
{
  "refresh_token": "jwt-string"
}
```

**Response:**
```json
{
  "access_token": "jwt-string",
  "refresh_token": "jwt-string"
}
```

**Implementación:**
1. Crear `AuthController.refresh/2` action
2. Validar refresh token con Guardian
3. Generar nuevo access token + nuevo refresh token (token rotation)
4. Invalidar refresh token anterior

### 4.3 Logout (G7)

**Request:**
```json
POST /auth/logout
Authorization: Bearer <access_token>
```

**Response:**
```json
{
  "message": "Logged out successfully"
}
```

**Implementación:**
1. Crear `AuthController.logout/2` action
2. Invalidar refresh tokens del usuario ( marcar como revoked en DB o usar denylist)

### 4.4 User ID como String (G9)

Modificar `Accounts.serialize_user/1` para convertir `id` a string:

```elixir
def serialize_user(user) do
  %{
    id: to_string(user.id),  # ← Convertir a string
    email: user.email,
    name: user.name,
    ...
  }
end
```

### 4.5 Avatar URL (G10)

Agregar campo `avatar_url` al schema de User y al serializer:

1. Agregar campo a migración: `add :avatar_url, :string`
2. Modificar serializer: `avatar_url: user.avatar_url`

---

## 5. Response Formats

### 5.1 Auth Response (login/register/social)

```json
{
  "access_token": "eyJhbGciOiJIUzI1NiIs...",
  "refresh_token": "eyJhbGciOiJIUzI1NiIs...",
  "token_type": "Bearer",
  "user": {
    "id": "1",
    "email": "user@example.com",
    "name": "Juan Pérez",
    "avatar_url": "https://example.com/avatar.jpg"
  }
}
```

### 5.2 Refresh Response

```json
{
  "access_token": "eyJhbGciOiJIUzI1NiIs...",
  "refresh_token": "eyJhbGciOiJIUzI1NiIs..."
}
```

### 5.3 Me Response

```json
{
  "id": "1",
  "email": "user@example.com",
  "name": "Juan Pérez",
  "avatar_url": "https://example.com/avatar.jpg"
}
```

### 5.4 Error Response

```json
{
  "error": "error_code",
  "message": "Human readable message"
}
```

---

## 6. Acceptance Criteria

- [ ] `POST /auth/login` devuelve access_token + refresh_token + user
- [ ] `POST /auth/register` devuelve access_token + refresh_token + user
- [ ] `POST /auth/google` funciona con provider "google"
- [ ] `POST /auth/facebook` funciona con provider "facebook"
- [ ] `POST /auth/apple` funciona con provider "apple"
- [ ] `POST /auth/refresh` genera nuevos tokens válidos
- [ ] `POST /auth/logout` invalida tokens
- [ ] `GET /auth/me` devuelve usuario actual
- [ ] `user.id` es string en todas las responses
- [ ] `user.avatar_url` presente en responses
- [ ] Todos los tests existentes pasan (272+)
- [ ] Nuevos tests para refresh y logout

---

## 7. Technical Approach

### 7.1 Tech Stack

- **Backend:** Elixir/Phoenix
- **Auth:** Guardian + Guardian.DB (para refresh tokens)
- **DB:** PostgreSQL

### 7.2 Dependencies

- `guardian` — JWT tokens
- `guardian_db` — Refresh token storage (si no está ya)
- `comeonin` — Password hashing (ya existe)

### 7.3 Files to Change

| File | Change |
|------|--------|
| `lib/meal_planner_api_web/router.ex` | Agregar route aliases |
| `lib/meal_planner_api/accounts.ex` | Modificar serialize_user |
| `lib/meal_planner_api_web/controllers/auth_controller.ex` | Agregar refresh/logout actions |
| `lib/meal_planner_api/accounts/user.ex` | Agregar avatar_url field |
| `priv/repo/migrations/*_add_avatar_url_to_users.exs` | Nueva migración |

### 7.4 Files to Create

| File | Purpose |
|------|---------|
| `test/meal_planner_api_web/controllers/auth_controller_test.exs` | Tests para auth endpoints |

---

## 8. Timeline

| Fase | Duración | Entregable |
|------|----------|------------|
| Route aliases (G1-G5, G8) | 30 min | Endpoints funcionando |
| User ID + avatar (G9, G10) | 30 min | Response format correcto |
| Refresh token (G6, G11) | 1 hr | Token rotation |
| Logout (G7) | 30 min | Endpoint logout |
| Tests | 30 min | 100% coverage auth |
| **Total** | **~3 hrs** | |

---

## 9. Risks

| Risk | Mitigation |
|------|------------|
| Cambiar serialize_user rompe otros consumers | Revisar todos los usages de serialize_user antes de cambiar |
| Refresh token rotation afecta sesión activa | Implementar grace period de 5 min para tokens vieja |
| Tests de integración fallan | Ejecutar suite completa después de cada cambio |

---

## 10. Out of Scope (Futuro)

- Métricas de uso / analytics
- Rate limiting en auth endpoints
- Device registration (multi-device support)
- 2FA / MFA