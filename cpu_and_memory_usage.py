import argparse
import psutil
import matplotlib.pyplot as plt
from datetime import datetime
import time
import os
import subprocess

"""
This script monitors CPU and memory usage over time and provides options to either write the data to a text file or plot it. 
If '--write-usage' option is provided, it continuously monitors CPU and memory usage and writes the data to the specified text file.
If '--plot-usage' option is provided, it reads CPU and memory usage data from the specified text file and plots it over time.
"""

def kill_job():
    try:
        with open("job_id.submitted", "r") as file:
            job_id = file.readline().strip()
            if job_id:
                subprocess.run(["scancel", job_id], check=True)
                print(f"Job {job_id} cancelled successfully.")
            else:
                print("No job ID found in job_id.submitted.")
    except FileNotFoundError:
        print("File job_id.submitted not found.")
    except subprocess.CalledProcessError as e:
        print(f"Failed to cancel job {job_id}. Error: {e}")

def get_usage():
    cpu_percent = psutil.cpu_percent()
    memory_percent = psutil.virtual_memory().percent
    return cpu_percent, memory_percent

def write_usage_data(txt_file):
    with open(txt_file, "w") as data_file:
        print("Monitoring CPU and memory usage...")
        while True:
            timestamp = datetime.now()
            cpu_usage, memory_usage = get_usage()
            if memory_usage > 98:
                kill_job()

            # Write data to file
            data_file.write(f"{timestamp},{cpu_usage},{memory_usage}\n")
            data_file.flush()

            # Wait for 1 second before collecting next data point
            time.sleep(1)


def plot_usage_data(txt_file):
    timestamps = []
    cpu_usages = []
    memory_usages = []

    try:
        with open(txt_file, "r") as data_file:
            print("Reading CPU and memory usage data...")
            for line in data_file:
                parts = line.strip().split(",")
                timestamp = datetime.fromisoformat(parts[0])
                cpu_usage = float(parts[1])
                memory_usage = float(parts[2])
                timestamps.append(timestamp)
                cpu_usages.append(cpu_usage)
                memory_usages.append(memory_usage)

        # Plot CPU and memory usage over time
        plt.figure(figsize=(10, 6))
        plt.plot(timestamps, cpu_usages, label='CPU Usage (%)')
        plt.plot(timestamps, memory_usages, label='Memory Usage (%)')
        plt.xlabel('Time')
        plt.ylabel('Usage (%)')
        plt.title('CPU and Memory Usage Over Time')
        plt.legend()
        plt.grid(True)
        plt.xticks(rotation=45)
        plt.tight_layout()

        # Save plot image
        img_path = os.path.splitext(txt_file)[0] + ".png"
        plt.savefig(img_path)
        print(f"Plot image saved as {img_path}")
    except FileNotFoundError:
        print(f"File '{txt_file}' not found.")

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="CPU and Memory Usage Monitor and Plotter")
    parser.add_argument("--write-usage", action="store_true", help="Write CPU and memory usage data to a text file")
    parser.add_argument("--plot-usage", action="store_true", help="Plot CPU and memory usage data from a text file")
    parser.add_argument("--txt", type=str, help="Specify the text file to read/write usage data")

    args = parser.parse_args()

    if args.write_usage and args.txt:
        write_usage_data(args.txt)
    elif args.plot_usage and args.txt:
        plot_usage_data(args.txt)
    else:
        print("Invalid arguments. Please specify '--write-usage' or '--plot-usage' along with '--txt' option.")
