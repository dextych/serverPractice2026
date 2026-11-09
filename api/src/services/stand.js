import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { execa } from 'execa';
import { AppError } from '../infrastructure/errors/appError.js';

const STAND_DIR = path.resolve(process.cwd(), 'stand/overlay-mesh-net');

export class Stand {
    static async executeControlScript(command) {
        try {
            const { stdout } = await execa('docker', [
                'compose',
                'exec',
                '-T',
                'stand',
                'python3',
                './scripts/control.py',
                command,
                '--json'
            ], {
                cwd: STAND_DIR,
                timeout: 5000
            });

            return JSON.parse(stdout);
        } catch (error) {
            throw new AppError(
                `Стенд недоступен или выключен: ${error.message}`,
                'STAND_UNAVAILABLE',
                502
            );
        }
    }

    static async getTopology() {
        return this.executeControlScript('topology');
    }

    static async getStatus() {
        return this.executeControlScript('status');
    }
}