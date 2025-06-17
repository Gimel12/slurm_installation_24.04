import subprocess
import pandas as pd
from flask import Flask, render_template, request, redirect, url_for, flash
import tempfile
import os

app = Flask(__name__)
app.secret_key = os.urandom(24)

def run_slurm_command(command):
    """Executes a Slurm command and returns its output."""
    try:
        result = subprocess.run(command, shell=True, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        return result.stdout, None
    except subprocess.CalledProcessError as e:
        return None, e.stderr

def parse_sinfo():
    """Parses sinfo output into an HTML table."""
    output, error = run_slurm_command("sinfo -o '%P %.10T %.15N %.12C %.10m %G'")
    if error:
        return f'<p class="error">Error fetching node status: {error}</p>'
    if not output.strip():
        return "<p>No nodes found or sinfo returned no output.</p>"
    
    lines = output.strip().split('\n')
    df = pd.DataFrame([x.split() for x in lines[1:]], columns=lines[0].split())
    return df.to_html(classes='table', index=False, border=0)

def parse_squeue():
    """Parses squeue output and adds a cancel button."""
    output, error = run_slurm_command("squeue -o '%.18i %.9P %.8j %.8u %.2t %.10M %.6D %R'")
    if error:
        return f'<p class="error">Error fetching job queue: {error}</p>'
    if not output.strip():
        return "<p>The job queue is empty.</p>"

    lines = output.strip().split('\n')
    df = pd.DataFrame([x.split() for x in lines[1:]], columns=lines[0].split())
    
    # Add a cancel button column
    df['ACTION'] = df['JOBID'].apply(lambda job_id: f'<a href="/cancel/{job_id}" role="button" class="secondary">Cancel</a>')
    return df.to_html(classes='table', index=False, border=0, escape=False)

@app.route('/')
def index():
    nodes_table = parse_sinfo()
    jobs_table = parse_squeue()
    return render_template('index.html', nodes_table=nodes_table, jobs_table=jobs_table)

@app.route('/submit', methods=['POST'])
def submit_job():
    job_script = request.form.get('job_script')
    if not job_script:
        flash('Job script cannot be empty.', 'error')
        return redirect(url_for('index'))

    # Normalize line endings to prevent DOS/UNIX errors
    job_script = job_script.replace('\r\n', '\n')

    try:
        # Create a temporary file to hold the script
        with tempfile.NamedTemporaryFile(mode='w', delete=False, suffix='.sbatch') as tmp:
            tmp.write(job_script)
            tmp_path = tmp.name
        
        # Submit the job using sbatch
        output, error = run_slurm_command(f'sbatch {tmp_path}')
        
        # Clean up the temporary file
        os.unlink(tmp_path)

        if error:
            flash(f'Error submitting job: {error}', 'error')
        else:
            flash(f'Successfully submitted job: {output.strip()}', 'success')

    except Exception as e:
        flash(f'An unexpected error occurred: {e}', 'error')

    return redirect(url_for('index'))

@app.route('/cancel/<job_id>')
def cancel_job(job_id):
    output, error = run_slurm_command(f'scancel {job_id}')
    if error:
        flash(f'Error canceling job {job_id}: {error}', 'error')
    else:
        flash(f'Successfully canceled job {job_id}.', 'success')
    return redirect(url_for('index'))

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000, debug=True)