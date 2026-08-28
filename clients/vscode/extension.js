'use strict';

const net = require('net');
const vscode = require('vscode');

let socket;
let buffer = '';
let sequence = 0;
let output;
const pending = new Map();

function config() {
  const value = vscode.workspace.getConfiguration('beamAgent');
  return {host: value.get('host'), port: value.get('port'), token: value.get('token')};
}

function connect() {
  if (socket && !socket.destroyed) return Promise.resolve();
  const {host, port, token} = config();
  if (!port || !token) return Promise.reject(new Error('Set beamAgent.port and beamAgent.token first'));

  return new Promise((resolve, reject) => {
    socket = net.createConnection({host, port}, resolve);
    socket.setEncoding('utf8');
    socket.on('data', data => {
      buffer += data;
      let newline;
      while ((newline = buffer.indexOf('\n')) >= 0) {
        const line = buffer.slice(0, newline); buffer = buffer.slice(newline + 1);
        if (!line) continue;
        const message = JSON.parse(line);
        if (message.type === 'response' && pending.has(message.request_id)) {
          pending.get(message.request_id)(message); pending.delete(message.request_id);
        } else {
          output.appendLine(JSON.stringify(message));
        }
      }
    });
    socket.on('error', reject);
    socket.on('close', () => { socket = undefined; });
  });
}

async function command(name, args = {}) {
  await connect();
  const id = `vscode-${++sequence}`;
  const request = {version: 1, request_id: id, command: name, arguments: args, token: config().token};
  return new Promise((resolve, reject) => {
    pending.set(id, response => response.ok ? resolve(response.result) : reject(new Error(response.error)));
    socket.write(JSON.stringify(request) + '\n');
  });
}

function activate(context) {
  output = vscode.window.createOutputChannel('BeamAgent');
  context.subscriptions.push(output);
  context.subscriptions.push(vscode.commands.registerCommand('beamAgent.connect', async () => {
    try { await connect(); vscode.window.showInformationMessage('Connected to BeamAgent'); }
    catch (error) { vscode.window.showErrorMessage(error.message); }
  }));
  context.subscriptions.push(vscode.commands.registerCommand('beamAgent.status', async () => {
    try { output.appendLine(JSON.stringify(await command('status'), null, 2)); output.show(); }
    catch (error) { vscode.window.showErrorMessage(error.message); }
  }));
  context.subscriptions.push(vscode.commands.registerCommand('beamAgent.submit', async () => {
    const prompt = await vscode.window.showInputBox({prompt: 'Ask BeamAgent'});
    if (prompt) command('submit', {prompt}).catch(error => vscode.window.showErrorMessage(error.message));
  }));
  context.subscriptions.push(vscode.commands.registerCommand('beamAgent.cancel', () =>
    command('cancel').catch(error => vscode.window.showErrorMessage(error.message))));
}

function deactivate() { if (socket) socket.destroy(); }

module.exports = {activate, deactivate};
