import requests
import time

URL = "http://localhost:8080/helloDoc/users"
SAMPLES = 5

def measure_requests():
    print(f"--- Замер времени для {URL} ---\n")
    
    # Рекомендуется использовать Session для переиспользования TCP-соединения,
    # если вам нужно замерить производительность самого API без учета рукопожатия
    with requests.Session() as session:
        for i in range(1, SAMPLES + 1):
            start_time = time.perf_counter()  # Высокоточный таймер
            
            try:
                response = session.get(URL, timeout=10)
                response.raise_for_status()
                
                duration = time.perf_counter() - start_time
                print(f"Запрос {i}: {duration:.4f} сек (Статус: {response.status_code})")
                
            except requests.exceptions.RequestException as e:
                print(f"Запрос {i}: Ошибка — {e}")

if __name__ == "__main__":
    measure_requests()
