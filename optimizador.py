import psycopg2
from ortools.linear_solver import pywraplp
import random

# =====================================================================
# 1. CONFIGURACIÓN
# =====================================================================
# ¡Acordate de poner tu contraseña real acá igual que en el otro script!
DB_URL = "postgresql://postgres.jwikygmivcovsrrdbvwn:TU_CONTRASEÑA@aws-1-sa-east-1.pooler.supabase.com:5432/postgres?sslmode=require"

try:
    conn = psycopg2.connect(DB_URL)
    cursor = conn.cursor()
    print("✅ Conectado a la base de datos para optimizar.")
except Exception as e:
    print(f"❌ Error conectando a la BD: {e}")
    exit()

# =====================================================================
# 2. SIMULADOR DE PRECIOS DEL SUPERMERCADO
# =====================================================================
def inyectar_precios_falsos():
    cursor.execute("SELECT COUNT(*) FROM precios_supermercado")
    if cursor.fetchone()[0] == 0:
        print("🛒 La tabla de precios está vacía. Inyectando precios simulados (x KG/Litro)...")
        cursor.execute("SELECT id_ingrediente FROM ingredientes")
        ingredientes = cursor.fetchall()
        
        for (id_ing,) in ingredientes:
            # Precios aleatorios lógicos: Carne/Queso más caro, Verduras más baratas
            if 'carne' in id_ing or 'pollo' in id_ing or 'queso' in id_ing:
                precio = random.randint(6000, 9000)
            elif 'cebolla' in id_ing or 'papa' in id_ing or 'arroz' in id_ing:
                precio = random.randint(1000, 2000)
            else:
                precio = random.randint(2500, 5000)
                
            cursor.execute("""
                INSERT INTO precios_supermercado (id_ingrediente, supermercado, precio_por_unidad, unidad_medida_precio)
                VALUES (%s, 'SuperMock', %s, 'kg')
                ON CONFLICT DO NOTHING
            """, (id_ing, precio))
        conn.commit()
        print("✅ Precios inyectados.")

# =====================================================================
# 3. EL CEREBRO MATEMÁTICO (OR-Tools)
# =====================================================================
def calcular_menu_optimo(dias=7, presupuesto_maximo=15000):
    # 1. Traemos las recetas y calculamos su costo real cruzando datos con SQL
    # Como los precios están por KG (1000g), dividimos la cantidad por 1000
    query = """
        SELECT 
            r.id_receta, 
            r.nombre, 
            SUM(ri.cantidad * (p.precio_por_unidad / 1000.0)) AS costo_total
        FROM recetas r
        JOIN receta_ingrediente ri ON r.id_receta = ri.id_receta
        JOIN precios_supermercado p ON ri.id_ingrediente = p.id_ingrediente
        GROUP BY r.id_receta, r.nombre
    """
    cursor.execute(query)
    recetas_db = cursor.fetchall()
    
    if len(recetas_db) < dias:
        print(f"⚠️ No hay suficientes recetas en la BD. Tenés {len(recetas_db)} y pediste {dias} días.")
        return

    # 2. Creamos el solver de Google
    solver = pywraplp.Solver.CreateSolver('SCIP')
    
    # 3. Variables de decisión (0 o 1 para cada receta)
    x = {}
    costos = {}
    nombres = {}
    
    for (id_receta, nombre, costo) in recetas_db:
        # Convertimos el costo a float por si viene como Decimal de la BD
        costo = float(costo)
        x[id_receta] = solver.BoolVar(nombre)
        costos[id_receta] = costo
        nombres[id_receta] = nombre

    # 4. RESTRICCIONES
    # A. Tienen que ser exactamente 7 comidas (dias)
    solver.Add(sum(x[id_receta] for id_receta in x) == dias)
    
    # B. El costo total de las recetas elegidas no puede superar el presupuesto
    solver.Add(sum(x[id_receta] * costos[id_receta] for id_receta in x) <= presupuesto_maximo)

    # 5. FUNCIÓN OBJETIVO
    # Le decimos que busque la combinación que gaste la MENOR cantidad de plata posible
    solver.Minimize(sum(x[id_receta] * costos[id_receta] for id_receta in x))

    # 6. RESOLVER
    print(f"\n🧠 OR-Tools analizando {len(recetas_db)} recetas...")
    print(f"Buscando {dias} comidas por menos de ${presupuesto_maximo}...\n")
    
    status = solver.Solve()

    # 7. RESULTADOS
    if status == pywraplp.Solver.OPTIMAL:
        print("🎉 ¡MENÚ ÓPTIMO ENCONTRADO!")
        print("="*40)
        costo_final = 0
        dia_num = 1
        
        for id_receta in x:
            if x[id_receta].solution_value() == 1.0:
                costo_plato = costos[id_receta]
                print(f"Día {dia_num}: {nombres[id_receta]} (${costo_plato:.2f})")
                costo_final += costo_plato
                dia_num += 1
                
        print("="*40)
        print(f"💰 Costo total de las 7 cenas: ${costo_final:.2f}")
        print(f"Sobró del presupuesto: ${presupuesto_maximo - costo_final:.2f}")
    else:
        print("❌ El algoritmo no pudo encontrar una solución.")
        print("Probablemente el presupuesto es demasiado bajo para 7 días con los precios actuales.")

if __name__ == "__main__":
    inyectar_precios_falsos()
    # Podés jugar cambiando los 15000 por 5000 o 30000 para ver cómo reacciona la matemática
    calcular_menu_optimo(dias=7, presupuesto_maximo=15000)
    
    cursor.close()
    conn.close()