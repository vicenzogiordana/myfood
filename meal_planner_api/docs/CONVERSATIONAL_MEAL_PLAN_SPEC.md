# PRD: Plan semanal de comidas posterior a una conversación

**Versión:** 0.1
**Estado:** Draft
**Alcance:** Especificación de producto; no describe una funcionalidad disponible

---

## 1. Problem Statement

Una persona necesita convertir una conversación sobre alimentación en un plan semanal verificable. El resultado debe cubrir desayuno, almuerzo y cena para cada día seleccionado, respetar objetivos nutricionales diarios, ingredientes requeridos y excluidos, dieta y presupuesto semanal.

El sistema actual contiene piezas útiles, pero no entrega todavía este flujo de punta a punta:

- `Generation.Server` arma candidatos y ejecuta el optimizador con un presupuesto leído por el servidor, pero hoy envía límites de macronutrientes deliberadamente permisivos.
- `PlanningCandidateBuilder` y `PlanningRepo` controlan los IDs de recetas, el alcance de cuenta, los participantes activos y las exclusiones persistidas.
- `optimizador.py` elige exactamente una receta por día y franja, aplica límites nutricionales por día y un límite de presupuesto sobre todo el período solicitado.
- Existe una frontera de intents tipados y una sesión de planificación capaz de guardar un intent validado, pero ese intent todavía no está conectado al pipeline canónico de generación.
- El perfil dietario persiste categorías limitadas, mientras que las recetas no tienen metadatos dietarios ni de alérgenos suficientes para demostrar compatibilidad general.

Sin un contrato común, una conversación puede parecer comprendida aunque sus restricciones no hayan llegado al conjunto canónico de candidatos ni al optimizador. Esto es especialmente riesgoso para exclusiones, presupuesto, datos faltantes y objetivos nutricionales extremos.

**Impacto:** La persona no puede confiar en que el plan propuesto represente lo conversado, y el producto no puede explicar de forma determinista por qué una combinación no tiene solución.

---

## 2. Solution

Crear un flujo de propuesta posterior a la conversación que:

1. interprete el lenguaje natural como un borrador de preferencias;
2. muestre una síntesis estructurada para confirmar o corregir;
3. resuelva participantes, perfil, presupuesto, moneda, ingredientes y recetas desde fuentes canónicas del servidor;
4. construya solamente candidatos elegibles;
5. optimice desayuno, almuerzo y cena para cada día seleccionado;
6. valide el resultado contra las restricciones confirmadas;
7. presente una propuesta sin persistir el calendario hasta una confirmación explícita;
8. explique conflictos, datos faltantes o inviabilidad sin inventar recetas, precios ni valores nutricionales.

La IA es un intérprete de intents. No tiene autoridad para seleccionar IDs de recetas, declarar nutrientes o precios, cambiar participantes, decidir alcance de cuenta ni ejecutar escrituras.

### 2.1 Resultado esperado

La propuesta muestra, como mínimo:

- rango semanal y días seleccionados;
- desayuno, almuerzo y cena por cada día seleccionado;
- receta canónica asignada a cada franja;
- totales diarios de calorías, proteínas, carbohidratos y grasas;
- costo estimado semanal en centavos y su moneda;
- restricciones duras satisfechas;
- preferencias blandas aplicadas o no aplicadas;
- advertencias por datos incompletos;
- explicación accionable cuando no existe una solución.

“Semanal” significa una ventana calendario de hasta siete días. Puede contener un subconjunto de días seleccionados, pero cada día incluido conserva las tres franjas requeridas. Un límite comercial por tier puede reducir la cantidad de días permitidos; no cambia silenciosamente la definición de semana.

### 2.2 Fuera de alcance

- Diagnóstico médico o recomendación clínica.
- Inventar umbrales clínicos mínimos o máximos.
- Crear recetas mediante IA para completar huecos.
- Inferir alérgenos o dietas a partir del nombre de una receta.
- Diseñar endpoints o payloads HTTP definitivos.
- Permitir que la IA confirme, persista o modifique el plan.
- Publicar issues, PRs o integraciones con trackers.

---

## 3. User Stories

### US1 — Días y franjas

Como persona que planifica su semana, quiero elegir los días para los que necesito comidas, para recibir desayuno, almuerzo y cena en cada uno.

### US2 — Nutrientes diarios

Como persona con objetivos alimentarios, quiero indicar rangos diarios deseados de calorías, proteínas, carbohidratos y grasas, para que el plan completo de cada día se evalúe contra ellos.

### US3 — Ingredientes requeridos

Como persona que quiere consumir un ingrediente, quiero pedirlo en la conversación, para que aparezca en al menos una comida de la semana por defecto.

### US4 — Ingredientes excluidos

Como participante con alergias, intolerancias o preferencias, quiero excluir ingredientes, para que ninguna receta candidata que los contenga sea elegible.

### US5 — Dieta

Como persona que sigue una dieta, quiero declarar categorías como vegetariana u ovo-lacto vegetariana, para recibir solamente recetas cuya compatibilidad esté demostrada por datos canónicos.

### US6 — Presupuesto

Como responsable de compras, quiero fijar un presupuesto semanal, para que el costo estimado total de las comidas seleccionadas no lo supere.

### US7 — Varios participantes

Como cuenta compartida, quiero seleccionar quiénes participan del plan, para que se apliquen las exclusiones de todos los participantes activos seleccionados.

### US8 — Conflictos e inviabilidad

Como persona usuaria, quiero saber qué restricción impide generar el plan y qué puedo cambiar, para decidir conscientemente sin que el sistema relaje reglas en secreto.

### US9 — Control antes de escribir

Como persona usuaria, quiero revisar la propuesta antes de confirmarla, para que una interpretación de IA nunca escriba directamente en mi calendario.

---

## 4. Reglas del producto

### 4.1 Restricciones duras

Una propuesta no es válida si incumple cualquiera de estas reglas:

- Hay exactamente una receta canónica para cada combinación de día seleccionado y franja `breakfast`, `lunch` o `dinner`.
- Todos los participantes son miembros activos de la cuenta y fueron seleccionados por una identidad autorizada.
- Ninguna receta contiene un ingrediente excluido por la conversación o por un participante seleccionado.
- La receta tiene compatibilidad dietaria canónica suficiente para demostrar la dieta confirmada.
- Cada rango nutricional diario confirmado se cumple sumando las tres comidas del día.
- El costo semanal conocido no supera el presupuesto efectivo resuelto por el servidor.
- Cada ingrediente requerido aparece al menos una vez en la ventana semanal, por defecto.
- Los IDs, nutrientes, ingredientes y precios usados para comprobar reglas provienen del servidor.

La inclusión semanal de un ingrediente solicitado es dura por defecto. La persona puede cambiarla explícitamente a preferencia blanda antes de generar; el sistema no la degrada automáticamente para encontrar una solución.

### 4.2 Preferencias blandas

Estas preferencias orientan el objetivo, pero no vuelven inválida una propuesta:

- priorizar inventario disponible;
- priorizar favoritos;
- minimizar costo por debajo del presupuesto;
- reducir repetición;
- preferir tiempos de preparación o estilos culinarios.

Una preferencia blanda nunca puede introducir una receta que viole una restricción dura. Si no se satisface, la propuesta debe indicarlo sin presentarlo como error de factibilidad.

### 4.3 Precedencia entre perfil y conversación

1. Las restricciones persistidas de los participantes seleccionados forman la base.
2. Las exclusiones expresadas en la conversación se agregan a esa base para la propuesta actual.
3. Una dieta conversacional más restrictiva puede acotar el perfil durante la propuesta.
4. Una dieta conversacional menos restrictiva no elimina silenciosamente una restricción persistida; requiere resolución explícita antes de generar.
5. La conversación prevalece sobre preferencias blandas del perfil sólo para la propuesta actual.
6. Ningún cambio conversacional modifica el perfil persistido salvo una acción separada y confirmada fuera de este flujo.

Cuando una misma entidad aparece como requerida y excluida, gana la exclusión dura y el sistema informa un conflicto antes de optimizar. No se genera una propuesta parcial ni se sustituye el ingrediente por similitud semántica.

### 4.4 Presupuesto, centavos y moneda

- El presupuesto y los costos se calculan como enteros en centavos; no se usan floats monetarios para decidir factibilidad.
- La moneda debe estar identificada y ser la misma para presupuesto y costos comparados.
- El servidor resuelve el máximo semanal autorizado de la cuenta. El presupuesto efectivo nunca puede superarlo, aunque la conversación pida más; si la persona confirma un valor menor, ese valor menor pasa a ser el límite efectivo.
- Si el máximo autorizado de la cuenta no puede resolverse, la generación falla de forma cerrada y no produce una propuesta.
- El límite efectivo aplica al total de todas las comidas de los días seleccionados dentro de la ventana semanal.
- Si una receta no tiene precio vigente, su costo es desconocido: no equivale a cero.
- En modo de presupuesto duro, una receta sin precio no puede usarse para demostrar que el plan está dentro del límite.
- Si faltan precios para toda solución posible, el resultado es inviable por datos de precio faltantes y debe explicarse como tal.

El código actual verifica `default_budget_cents` en la cuenta y contiene un objeto de dominio de presupuesto con moneda; sin embargo, la cuenta no persiste una moneda junto al presupuesto y otros servicios usan `ARS` como fallback. La fuente canónica de moneda queda como decisión pendiente.

### 4.5 Nutrientes y objetivos muy bajos

- Los objetivos se expresan como rangos diarios confirmados: mínimo y máximo para calorías, proteínas, carbohidratos y grasas.
- Los valores deben ser numéricos no negativos y cada mínimo debe ser menor o igual que su máximo.
- Los totales se calculan con valores canónicos por porción y la cantidad de porciones aplicable.
- Un valor faltante no se transforma en cero para demostrar cumplimiento.
- Un objetivo potencialmente muy bajo debe mostrarse de manera explícita y requerir confirmación antes de optimizar.
- El producto no inventa un piso clínico ni afirma que el objetivo es seguro. Debe aclarar que no brinda consejo médico y dirigir a una fuente profesional cuando corresponda.
- Hasta contar con una política de seguridad validada, confirmar el valor evita errores de interpretación pero no constituye validación clínica.

### 4.6 Dietas, alérgenos y taxonomía desconocida

El perfil actual conoce `omnivore`, `vegetarian`, `vegan`, `pescatarian` y `celiac`. Esto no demuestra que las recetas estén clasificadas con esa taxonomía. Tampoco existe evidencia suficiente de metadatos exhaustivos de alérgenos en las recetas.

Por lo tanto:

- las exclusiones de la conversación y de todos los participantes seleccionados se aplican conjuntamente;
- una dieta o exclusión sólo puede aplicarse automáticamente cuando la compatibilidad se deriva de datos estructurados completos;
- las familias de ingredientes y los alérgenos derivados requieren metadata canónica para excluir también variantes y derivados relevantes;
- la ausencia de una marca de alérgeno no significa ausencia del alérgeno;
- una receta con metadata desconocida no es elegible para una restricción dura que dependa de esa metadata;
- `celiac` no debe tratarse como una preferencia estética ni inferirse por texto;
- “carnívora” y “ovo-lacto vegetariana” requieren una taxonomía explícita antes de ser soportadas como restricciones duras;
- el sistema sólo verifica composición según su metadata canónica: no afirma seguridad clínica ni ausencia de contaminación cruzada.

---

## 5. Flujo conversacional propuesto

1. **Interpretar:** la IA extrae días, rangos nutricionales, inclusiones, exclusiones, dieta y un presupuesto solicitado como un intent tipado no ejecutable. Si incluye IDs autoritativos, precios, nutrientes declarados como autoritativos, participantes o directivas de escritura, el intent completo es inválido y se rechaza; no se descartan campos para continuar.
2. **Normalizar:** sólo para un intent válido, el servidor resuelve por separado participantes, unidades, centavos, moneda, ingredientes y demás datos autoritativos contra fuentes canónicas.
3. **Reconciliar:** el servidor combina perfil y conversación según la precedencia definida.
4. **Confirmar comprensión:** la interfaz muestra una síntesis separando restricciones duras, preferencias blandas, advertencias y datos no resueltos.
5. **Construir candidatos:** `PlanningCandidateBuilder` usa cuenta, participantes activos, franjas y filtros canónicos. La IA no aporta IDs.
6. **Optimizar:** el optimizador aplica una comida por franja, límites diarios, inclusión semanal y presupuesto semanal.
7. **Validar:** el servidor vuelve a calcular cumplimiento sobre la respuesta del optimizador y rechaza IDs o valores fuera del conjunto canónico.
8. **Proponer:** se muestra el plan y sus totales sin escribir comidas programadas.
9. **Confirmar:** sólo una acción autorizada y explícita entra al flujo transaccional de persistencia.

Si la normalización produce más de una interpretación razonable de un ingrediente, dieta, moneda o participante, el flujo pide una aclaración cerrada antes de construir candidatos.

---

## 6. Implementation Decisions and Seams

| Área | Decisión o seam |
|---|---|
| Interpretación | Reutilizar la frontera de intents tipados como entrada no autoritativa. Rechazar el intent completo si contiene IDs, precios, nutrientes autoritativos, participantes o directivas de escritura; no sanearlo parcialmente para continuar. |
| Sesión | La sesión conserva el borrador confirmado y su rango; hoy puede guardar un intent validado, pero falta conectarla al pipeline canónico. |
| Participantes | Resolverlos por separado en el servidor, sólo entre membresías activas de la cuenta; rechazar IDs desconocidos o externos en lugar de ignorarlos. |
| Candidatos | Mantener `PlanningCandidateBuilder` como única puerta de recetas hacia optimización. |
| Exclusiones | Mantener `PlanningRepo` como filtro canónico de ingredientes excluidos de los participantes y sumar exclusiones conversacionales normalizadas en la misma etapa de elegibilidad. |
| Dieta | Agregar una clasificación canónica verificable antes de filtrar; no usar el nombre o texto generado de una receta como prueba. |
| Ingrediente requerido | Incorporar una restricción semanal de cobertura: al menos una receta elegida contiene cada ingrediente requerido duro. |
| Nutrientes | Reemplazar los límites permisivos de `Generation.Server` por rangos diarios confirmados y validados por el servidor. |
| Presupuesto | Resolver el máximo autorizado de cuenta y usar como límite efectivo el menor entre ese máximo y el valor inferior confirmado; fallar de forma cerrada si no puede resolverse. Nunca aceptar costos declarados por IA. |
| Precio faltante | Representar desconocido de forma distinta de cero y excluirlo de una prueba de presupuesto duro. |
| Optimización | Extender `optimizador.py` en su seam actual: restricciones diarias para nutrientes y globales para presupuesto e inclusiones semanales. |
| Resultado | Validar receta, slot, fecha, nutrientes, precio e inclusión contra el snapshot canónico usado al optimizar. |
| Persistencia | Separar propuesta de confirmación; mantener las escrituras detrás de la transacción autorizada del servidor. |
| Explicabilidad | Devolver causas estructuradas de inviabilidad sin relajar restricciones automáticamente. |

No se fija aquí una forma exacta de API. Los nombres de intents, eventos o campos externos deben definirse después de verificar el transporte que será canónico.

---

## 7. Acceptance Scenarios

### AC1 — Tres comidas por día seleccionado

**Dado** un rango semanal y tres días seleccionados con candidatos elegibles  
**Cuando** se genera una propuesta  
**Entonces** contiene exactamente desayuno, almuerzo y cena para cada día seleccionado  
**Y** no agrega comidas para días no seleccionados.

### AC2 — Nutrientes diarios

**Dado** un rango confirmado para cada nutriente soportado  
**Cuando** se valida una propuesta  
**Entonces** la suma canónica de las tres comidas de cada día cae dentro de los mínimos y máximos de ese día  
**Y** un dato nutricional faltante no se cuenta como cero.

### AC3 — Ingrediente requerido por defecto

**Dado** que la persona pide incluir lentejas sin marcar la petición como blanda  
**Cuando** se genera la semana  
**Entonces** al menos una receta elegida contiene el ID canónico de lentejas  
**Y** una semana sin lentejas se rechaza como inválida.

### AC4 — Exclusiones combinadas y metadata canónica

**Dado** que la conversación excluye maní y un participante seleccionado excluye una familia o alérgeno derivado  
**Cuando** se construyen candidatos  
**Entonces** se aplican conjuntamente ambas exclusiones usando IDs, familias y derivados de metadata canónica  
**Y** una receta con metadata insuficiente no es elegible  
**Y** inventario o favoritos no pueden reintroducirla  
**Y** el resultado no afirma seguridad clínica ni ausencia de contaminación cruzada.

### AC5 — Inclusión y exclusión en conflicto

**Dado** que el mismo ingrediente normalizado está requerido y excluido  
**Cuando** se confirma la síntesis conversacional  
**Entonces** la exclusión prevalece  
**Y** se informa el conflicto antes de optimizar  
**Y** no se relaja ninguna de las dos reglas en secreto.

### AC6 — Dieta demostrable

**Dado** un plan vegetariano confirmado  
**Cuando** una receta carece de metadata suficiente para demostrar compatibilidad  
**Entonces** esa receta no es elegible  
**Y** el sistema distingue “metadata desconocida” de “receta incompatible”.

### AC7 — Presupuesto efectivo y moneda

**Dado** un máximo autorizado de cuenta de 50.000 centavos y un pedido conversacional mayor en la misma moneda  
**Cuando** se genera una propuesta  
**Entonces** el límite efectivo sigue siendo 50.000 centavos y el costo semanal no lo supera  
**Y** si la persona confirma un límite menor, se aplica ese valor menor y el costo tampoco lo supera  
**Y** si el máximo de cuenta no puede resolverse, no se genera ninguna propuesta  
**Y** el resultado muestra total, centavos y moneda.

### AC8 — Precio faltante

**Dado** un presupuesto duro y una receta sin precio vigente  
**Cuando** se evalúa esa receta  
**Entonces** su precio se considera desconocido, no cero  
**Y** no puede usarse para probar cumplimiento del presupuesto  
**Y** si no queda solución, la causa reportada identifica precios faltantes.

### AC9 — Inviabilidad explicable

**Dado** que ninguna combinación satisface simultáneamente franjas, dieta, exclusiones, inclusiones, nutrientes y presupuesto  
**Cuando** termina la optimización  
**Entonces** no se entrega un plan que parezca válido  
**Y** se informan las restricciones duras ajustables que causan la inviabilidad  
**Y** las preferencias blandas no se presentan como causa dura.

### AC10 — Precedencia de perfil

**Dado** un perfil vegetariano y una conversación que pide una dieta menos restrictiva  
**Cuando** se reconcilian restricciones  
**Entonces** el sistema no elimina el perfil silenciosamente  
**Y** solicita resolución explícita antes de generar  
**Y** cualquier elección temporal no modifica el perfil persistido.

### AC11 — Participantes canónicos

**Dado** un conjunto solicitado de participantes  
**Cuando** uno no es miembro activo de la cuenta  
**Entonces** el servidor rechaza o pide corregir la selección  
**Y** no genera ignorando silenciosamente a esa persona  
**Y** agrega las exclusiones de todos los participantes activos seleccionados.

### AC12 — Objetivo nutricional potencialmente muy bajo

**Dado** un objetivo diario que el producto identifica como potencialmente muy bajo según una política validada  
**Cuando** se confirma la síntesis  
**Entonces** se muestra el valor exacto y una advertencia no clínica  
**Y** se requiere confirmación explícita  
**Y** el sistema no inventa un límite médico ni afirma seguridad.

### AC13 — Autoridad de la IA

**Dado** un intent producido por IA que contiene IDs autoritativos, precios, nutrientes autoritativos, participantes o una directiva de escritura  
**Cuando** cruza la frontera tipada  
**Entonces** el servidor rechaza el intent completo como inválido  
**Y** no descarta parcialmente esos campos para continuar  
**Y** los datos autoritativos se resuelven por separado desde fuentes canónicas sólo a partir de un intent válido  
**Y** ninguna comida se persiste por esa interpretación.

### AC14 — Alcance semanal y tier

**Dado** que la persona selecciona días dentro de una ventana de hasta siete días  
**Cuando** su tier permite menos días que los solicitados  
**Entonces** el sistema informa el límite antes de optimizar  
**Y** no recorta días silenciosamente  
**Y** mantiene desayuno, almuerzo y cena en cada día finalmente aceptado.

### AC15 — Confirmación separada

**Dado** un plan factible mostrado como propuesta  
**Cuando** la persona todavía no lo confirmó  
**Entonces** no existen nuevas comidas programadas por ese plan  
**Y** sólo una confirmación autorizada puede iniciar la escritura server-side.

---

## 8. Grounding verificado en el código

| Evidencia | Estado observado |
|---|---|
| `lib/meal_planner_api/generation/server.ex` | El servidor arma slots, toma presupuesto de cuenta, usa límites macro `0..1_000_000`, valida la respuesta y confirma mediante una transacción. |
| `lib/meal_planner_api/services/planning_candidate_builder.ex` | El servidor arma candidatos con IDs, costos, nutrientes e inventario; un costo faltante hoy cae en `0`. |
| `lib/meal_planner_api/data/planning_repo.ex` | Las recetas se acotan por cuenta y slot; las exclusiones se agregan para participantes activos seleccionados. |
| `optimizador.py` | Existe una elección exacta por día/franja, límites nutricionales diarios y presupuesto global; todavía no existe cobertura de ingredientes requeridos. |
| `lib/meal_planner_api/services/generation_service.ex` | La frontera tipada prohíbe IDs de receta/propuesta/comida e instrucciones de escritura. |
| `lib/meal_planner_api/generation/planning_session_server.ex` | La sesión valida y guarda un intent pendiente, con comentario explícito de cableado futuro. |
| `lib/meal_planner_api/persistence/accounts/user_dietary_profile.ex` | La taxonomía persistida es limitada y no incluye ovo-lacto ni carnívora. |
| `lib/meal_planner_api/persistence/catalog/recipe.ex` | La receta tiene macros y slots, pero no campos dietarios ni de alérgenos. |
| `lib/meal_planner_api/planning.ex` | El flujo de compatibilidad limita a siete días para premium y cinco para otros; falta decidir cómo se aplica al pipeline canónico. |

Estas observaciones son estado actual, no evidencia de que el producto descrito ya esté disponible.

---

## 9. Decisiones pendientes

1. **Taxonomía carnívora:** definir si significa sólo productos animales, si admite condimentos o vegetales, y qué variantes se soportan.
2. **Ovo-lacto vegetariana:** decidir si será categoría propia o composición explícita de inclusiones y exclusiones.
3. **Metadatos dietarios y alérgenos:** elegir fuente, cobertura mínima, versionado y política para datos desconocidos.
4. **Objetivos numéricos con varios participantes:** decidir si se optimiza un rango compartido, porciones por persona o múltiples objetivos individuales; no promediar por defecto.
5. **Porciones:** definir cómo escalan nutrientes y costos para participantes distintos y si cada comida puede tener cantidades individuales.
6. **Moneda canónica:** decidir dónde se persiste y cómo se rechazan o convierten costos en monedas distintas; no asumir que `ARS` siempre aplica.
7. **Tier y semana:** confirmar si el pipeline canónico adopta 5 días para tiers no premium y 7 para premium, y cuál es la autoridad vigente del tier.
8. **Política para objetivos muy bajos:** obtener una regla de producto validada por especialistas sin convertir esta especificación en guía clínica.
9. **Precio faltante:** confirmar si siempre excluye candidatos bajo presupuesto duro o si existe un modo explícito de estimación, claramente no garantizado.
10. **Granularidad de ingredientes requeridos:** decidir si “al menos una vez” se evalúa por ingrediente base, variante, cantidad mínima o unidad normalizada.
11. **Persistencia de conversación:** decidir qué parte del intent confirmado queda auditada y por cuánto tiempo, sin guardar texto sensible innecesario.
12. **Transporte canónico:** decidir qué channel o flujo invoca la sesión tipada y retira caminos conversacionales legacy.
