import asyncio
import httpx
import time
import threading
import multiprocessing
from concurrent.futures import ThreadPoolExecutor, ProcessPoolExecutor
from fastapi import FastAPI

app = FastAPI()
URL = "https://jsonplaceholder.typicode.com/posts/1"
NUM_REQUESTS = 5

# Synchronous function to fetch API data
def fetch_data(url):
    response = httpx.get(url)
    return response.json()

# Threading Implementation
def threading_fetch():
    with ThreadPoolExecutor(max_workers=NUM_REQUESTS) as executor:
        results = list(executor.map(fetch_data, [URL] * NUM_REQUESTS))
    return results

# Multiprocessing Implementation
def multiprocessing_fetch():
    with ProcessPoolExecutor(max_workers=NUM_REQUESTS) as executor:
        results = list(executor.map(fetch_data, [URL] * NUM_REQUESTS))
    return results

# Hybrid Threading + Multiprocessing
def hybrid_fetch():
    def thread_worker():
        return fetch_data(URL)
    
    with ProcessPoolExecutor(max_workers=2) as proc_executor:
        results = list(proc_executor.map(lambda _: threading_fetch(), range(2)))
    return results

@app.get("/threading")
def threading_route():
    start_time = time.time()
    results = threading_fetch()
    end_time = time.time()
    return {"execution_time": end_time - start_time, "results": results}

@app.get("/multiprocessing")
def multiprocessing_route():
    start_time = time.time()
    results = multiprocessing_fetch()
    end_time = time.time()
    return {"execution_time": end_time - start_time, "results": results}

@app.get("/hybrid")
def hybrid_route():
    start_time = time.time()
    results = hybrid_fetch()
    end_time = time.time()
    return {"execution_time": end_time - start_time, "results": results}

@app.get("/health")
def health_check():
    return {"status": "healthy"}
