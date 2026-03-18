from google import genai
from google.genai import types
import psycopg2
import uuid
import json
import time

# =====================================================================
# 1. CONFIGURACIÓN (¡Poné tu contraseña real de Supabase acá!)
# =====================================================================
API_KEY = "AIzaSyC7s6MbypUeKaKW0z3CC5olMOZwFSULKZs" 
# Ejemplo de cómo debe verse: "postgresql://postgres:MiContraSecreta123@db.jwikygmivcov...supabase.co:5432/postgres"
# DB_URL = "postgresql://postgres:xEl3eTXfzx7bJf3H@db.jwikygmivcovsrrdbvwn.supabase.co:5432/postgres"
DB_URL = "postgresql://postgres.jwikygmivcovsrrdbvwn:xEl3eTXfzx7bJf3H@aws-1-sa-east-1.pooler.supabase.com:5432/postgres?sslmode=require"

# Inicializamos el nuevo cliente de Gemini
client = genai.Client(api_key=API_KEY)

# =====================================================================
# 2. CONEXIÓN A LA BASE DE DATOS
# =====================================================================
try:
    conn = psycopg2.connect(DB_URL)
    cursor = conn.cursor()
    print("✅ Conectado a la base de datos PostgreSQL exitosamente.")
except Exception as e:
    print(f"❌ Error crítico conectando a la BD: {e}")
    exit()

# =====================================================================
# 3. EL MOTOR DE GENERACIÓN (La IA)
# =====================================================================
def generar_recetas(tematica):
    print(f"🧠 Procesando solicitud con Gemini: '{tematica}'...")
    
    prompt = """
    Actúa como un chef y nutricionista experto de Argentina.
    Genera un array JSON con 25 recetas sobre la temática solicitada.
    
    REGLA ESTRICTA PARA INGREDIENTES:
    Para el campo 'id_ingrediente', DEBES usar exclusivamente los IDs de esta lista: 
    ['ing_carne_picada', 'ing_pollo_pechuga', 'ing_pollo_pata_muslo', 'ing_carne_milanesa', 'ing_bife_chorizo', 'ing_cerdo_costillita', 'ing_huevo', 'ing_atun_lata', 'ing_jamon_cocido', 'ing_cebolla', 'ing_cebolla_verdeo', 'ing_papa', 'ing_batata', 'ing_tomate', 'ing_tomate_cherry', 'ing_zanahoria', 'ing_morron_rojo', 'ing_morron_verde', 'ing_lechuga', 'ing_zapallo_anco', 'ing_zapallito', 'ing_ajo', 'ing_espinaca', 'ing_acelga', 'ing_limon', 'ing_arroz_blanco', 'ing_arroz_integral', 'ing_fideos_tallarines', 'ing_fideos_tirabuzon', 'ing_lentejas', 'ing_garbanzos', 'ing_harina_trigo', 'ing_pan_rallado', 'ing_tapa_empanada', 'ing_tapa_tarta', 'ing_queso_cremoso', 'ing_queso_rallado', 'ing_queso_crema', 'ing_leche', 'ing_manteca', 'ing_crema_leche', 'ing_aceite_girasol', 'ing_aceite_oliva', 'ing_pure_tomate', 'ing_sal', 'ing_pimienta', 'ing_oregano', 'ing_pimenton', 'ing_provenzal', 'ing_mostaza', 'ing_mayonesa']
    
    Debes respetar exactamente esta estructura JSON y no devolver markdown ni texto fuera del JSON:
    [
      {
        "nombre": "string",
        "porciones": entero,
        "calorias_por_porcion": entero,
        "proteinas_g": entero,
        "carbohidratos_g": entero,
        "grasas_g": entero,
        "instrucciones": "string con los pasos separados por punto",
        "ingredientes": [
           {"id_ingrediente": "string exacto de la lista permitida", "cantidad": decimal, "unidad": "g o ml"}
        ]
      }
    ]
    """
    
    # Nueva sintaxis para llamar a la API y forzar JSON
    response = client.models.generate_content(
        model='gemini-2.5-flash',
        contents=f"Temática: {tematica}. \n{prompt}",
        config=types.GenerateContentConfig(
            response_mime_type="application/json",
        )
    )
    
    return json.loads(response.text)

# =====================================================================
# 4. GUARDADO EN BASE DE DATOS
# =====================================================================
def guardar_en_db(recetas):
    for receta in recetas:
        id_receta = str(uuid.uuid4())
        
        try:
            cursor.execute("""
                INSERT INTO recetas (id_receta, nombre, porciones, calorias_por_porcion, proteinas_g, carbohidratos_g, grasas_g, instrucciones)
                VALUES (%s, %s, %s, %s, %s, %s, %s, %s)
            """, (id_receta, receta['nombre'], receta['porciones'], receta['calorias_por_porcion'], 
                  receta['proteinas_g'], receta['carbohidratos_g'], receta['grasas_g'], receta['instrucciones']))
            
            for ing in receta['ingredientes']:
                cursor.execute("""
                    INSERT INTO receta_ingrediente (id_receta, id_ingrediente, cantidad, unidad)
                    VALUES (%s, %s, %s, %s)
                    ON CONFLICT DO NOTHING
                """, (id_receta, ing['id_ingrediente'], ing['cantidad'], ing['unidad']))
            
            conn.commit()
            print(f"💾 Guardada exitosamente: {receta['nombre']}")
            
        except Exception as e:
            conn.rollback()
            print(f"⚠️ Error guardando '{receta['nombre']}': {e}")

# =====================================================================
# 5. EJECUCIÓN PRINCIPAL
# =====================================================================
if __name__ == "__main__":
    print("🚀 Iniciando el Generador de Recetas...")
    
    tematicas_argentinas = [
    # --- ECONÓMICAS Y FIN DE MES ---
    # "Almuerzos económicos para estudiantes",
    # "Menú de fin de mes con muy poco presupuesto",
    # "Recetas salvadoras con 5 ingredientes o menos",
    # "Comidas que rinden para varios días",
    # "Recetas baratas con carne picada",
    # "Platos con pollo trozado económico",
    # "Cenas con cortes de cerdo baratos",
    # "Platos con carne de vaca económica (roast beef, paleta)",
    # "Comidas para aprovechar sobras de pollo",
    # "Recetas para no tirar el pan duro",
    
    # # --- RÁPIDAS Y PRÁCTICAS ---
    # "Cenas rápidas en menos de 30 minutos",
    # "Almuerzos rápidos para hacer home office",
    # "Cenas fáciles que ensucian pocos platos",
    # "Recetas fáciles en una sola sartén",
    # "Tortillas y revueltos rápidos",
    # "Comidas que se pueden freezar fácilmente",
    # "Platos con latas de atún para salir del apuro",
    # "Cenas fáciles usando el microondas",
    # "Recetas rápidas para cuando llegás tarde del trabajo",
    # "Platos con salchichas para salir del apuro",

    # # --- CLÁSICOS ARGENTINOS Y BODEGÓN ---
    # "Clásicos de bodegón porteño",
    # "Milanesas y sus mejores guarniciones",
    # "Pastas del domingo en familia",
    # "Salsas clásicas argentinas para pastas",
    # "Comidas típicas de los domingos al mediodía",
    # "Guarniciones ricas para acompañar el asado",
    # "Platos tradicionales patrios argentinos",
    # "Platos típicos del norte argentino",
    # "Platos típicos de la Patagonia",
    # "Minutas argentinas para hacer en casa",
    
    # --- VIANDAS Y FACULTAD ---
    # "Viandas frías para llevar a la facultad",
    # "Almuerzos abundantes para trabajadores",
    "Ensaladas completas que sirven de plato principal",
    "Sándwiches contundentes y completos",
    "Picadas argentinas económicas",
    "Snacks salados y saludables para estudiar",
    "Tartas saladas fáciles y rendidoras",
    "Rellenos de empanadas tradicionales",
    "Recetas de empanadas abiertas o canastitas",
    "Platos para compartir con amigos",

    # --- SALUDABLES Y DIETAS ---
    "Opciones saludables con pechuga de pollo",
    "Cenas livianas y saludables",
    "Almuerzos proteicos para entrenar",
    "Opciones sin TACC (libres de gluten) económicas",
    "Recetas vegetarianas con ingredientes de supermercado",
    "Menú vegano con ingredientes baratos",
    "Almuerzos bajos en carbohidratos",
    "Cenas altas en proteínas y bajas en grasas",
    "Cenas para mejorar la digestión",
    "Almuerzos tipo 'bowl' saludables",

    # --- INGREDIENTES ESPECÍFICOS ---
    "Recetas ricas con arroz blanco o integral",
    "Platos con papas como ingrediente principal",
    "Recetas con batata o boniato",
    "Recetas con zapallitos verdes o calabaza",
    "Recetas con acelga o espinaca",
    "Recetas con legumbres como lentejas y garbanzos",
    "Preparaciones con huevo como protagonista",
    "Platos principales con mucho queso derretido",
    "Platos con filet de merluza",
    "Recetas donde la cebolla es protagonista",
    
    # --- CLIMA Y ESTACIONES ---
    "Comidas de invierno para entrar en calor",
    "Comida de olla y guisos económicos",
    "Cenas reconfortantes para días de lluvia",
    "Comidas frías para días de mucho calor",
    "Cenas ligeras para noches de verano",
    "Ensaladas tibias para el otoño",
    "Platos al horno que se cocinan solos",
    "Platos que llevan vino en su cocción",
    "Comidas típicas con mucho ajo y perejil (provenzal)",
    "Guisos sin carne (opciones vegetales)",

    # --- VARIOS Y CREATIVOS ---
    "Comida chatarra versión casera y sana",
    "Menú infantil que los chicos amen",
    "Pizzas caseras y variantes",
    "Rellenos para panqueques salados",
    "Guarniciones originales con verduras",
    "Rellenos creativos para tomates o zapallitos",
    "Menú de pascuas barato sin carne roja",
    "Platos para cocinar en equipo o en pareja",
    "Recetas fáciles usando polenta",
    "Platos con fiambres como jamón y queso",
    "Recetas de panificados salados rápidos",
    "Menú ideal para ver partidos de fútbol",
    "Recetas con choclo o maíz",
    "Croquetas y buñuelos fritos o al horno",
    "Platos reconfortantes que hacía la abuela",
    "Salsas blancas y sus variantes",
    "Woks de fideos y vegetales",
    "Platos agridulces caseros",
    "Salsas para carnes a la plancha",
    "Platos al escabeche o vinagreta",
    "Recetas usando masa de empanadas de forma original",
    "Cenas rápidas con tomates frescos o puré",
    "Almuerzos con extra fibra",
    "Almuerzos pesados para días de mucho desgaste físico",
    "Recetas ricas con fideos secos",
    "Carnes al horno con papas estilo fonda",
    "Tartas sin masa (al plato) para cuidar la silueta",
    "Platos que no fallan para invitados sorpresa",
    "Platos maestros para lucirse gastando poco",
    "Desayunos o meriendas proteicas saladas"
]
    
    for tema in tematicas_argentinas:
        try:
            nuevas = generar_recetas(tema)
            guardar_en_db(nuevas)

            # Frenamos la ejecución 30 segundos para cuidar el límite de la API
            print("⏳ Pausa táctica de 30 segundos para no saturar el servidor...")
            time.sleep(30)
            print("-" * 40)
        except Exception as e:
             print(f"❌ Error en la temática '{tema}': {e}")
             # Si llega a fallar por límite, lo hacemos descansar un minuto entero
             print("⏳ Esperando 60 segundos por seguridad antes de seguir...")
             time.sleep(60)
             continue
             
    cursor.close()
    conn.close()
    print("🏁 Proceso finalizado.")